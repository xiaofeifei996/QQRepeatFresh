/*
 * QQRepeatOnly - Fresh 0.2.0 (2026-10-20)
 *
 * 全新提取自 QQ 净化 dylib 中 QQCK.repeater 双击复读模块，重写为独立 dylib。
 * 关键点：
 *  - UIViewController viewDidAppear:(AIOChat/NTAIOChatTable) -> 1.5s节流 -> 0.3s延迟 -> QQRPScanUI
 *  - NTAIOCellView 系 cell 内容视图逐个挂双击手势(2 taps/1 touch, cancels=NO)
 *  - record = cell->viewModel 深度对象图搜索(14 个候选 ivar 名, 深度<=4, visited 去重)
 *  - 判据: respondsToSelector(msgId/msgSeq/peerUid/msgType)
 *  - 发送 = [QSLManager getInstance].msgService forwardMsg:@[NSNumber(msgid)] srcContact:contact
 *            dstContacts:@[contact] msgAttributeInfos:nil cb:nil
 *  - contact = record.contact 或 [OCContact ContactWithChatType:(int)peerUid:guildId:]
 *    (chatType 是标量 int, 不是对象!)
 *  - 同一 record 0.65s 节流; 允许复读自己发的消息(去掉原版 IsSelf gate)
 *  - 对象读取仅 selector 访问器(返回类型'@'校验)或 KVC valueForKey:
 *    禁止 raw object_getIvar (QQ NT 中 viewModel 是 Swift/weak 引用, 裸读崩)
 *  - 调试日志: QQ沙盒 Documents/QQRepeatOnly.log
 */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <dispatch/dispatch.h>
#import <stdlib.h>

#define QQRP_VERSION @"0.2.1"

// ================= 日志 =================

static NSString *QQRPLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *docs =
            [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
        path = [docs stringByAppendingPathComponent:@"QQRepeatOnly.log"];
    });
    return path;
}

static void QQRPLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void QQRPLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [[NSDateFormatter alloc] init]; df.dateFormat = @"MM-dd HH:mm:ss"; });
    NSString *line = [NSString stringWithFormat:@"[%@] %@\n", [df stringFromDate:[NSDate date]], msg];
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0), ^{
        NSString *p = QQRPLogPath();
        if (!p) return;
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:p];
        if (!fh) {
            [line writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            return;
        }
        @try {
            [fh seekToEndOfFile];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        } @catch (NSException *e) {}
        [fh closeFile];
    });
}

// ================= 开关 =================

static BOOL QQRPEnabled(void) {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if ([ud objectForKey:@"QQRPEnabled"] == nil) return YES; // 默认开启
    return [ud boolForKey:@"QQRPEnabled"];
}

// ================= 类名工具 =================

static NSString *QQRPClassStr(id obj) {
    if (!obj) return @"(nil)";
    return NSStringFromClass(object_getClass(obj)) ?: @"(null)";
}

// 返回类型读取 (method_copyReturnType: malloc, 需 free)
static char *QQRPReturnTypeCopy(Method m) {
    if (!m) return NULL;
    return method_copyReturnType(m); // caller frees
}

// ================= 安全对象读取 =================
// 只用两种途径: (a) selector 访问器(method_getReturnType=='@' 校验)
//              (b) KVC valueForKey: (对 weak ivar 安全, 不会 raw deref)
// 绝不 object_getIvar / object_getInstanceVariable。

static id QQRPCallObjectGetter(id obj, SEL sel) {
    if (!obj || !sel) return nil;
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) return nil;
    char *rt = QQRPReturnTypeCopy(m);
    BOOL ok = (rt && rt[0] == '@');
    free(rt);
    if (!ok) return nil;
    id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
    return send(obj, sel);
}

// 优先 selector 访问器, 失败则 KVC
static id QQRPSafeIvar(id obj, NSString *name) {
    if (!obj || name.length == 0) return nil;
    if (![(id)obj isKindOfClass:[NSObject class]]) return nil;
    SEL sel = NSSelectorFromString(name);
    if ([obj respondsToSelector:sel]) {
        Method m = class_getInstanceMethod(object_getClass(obj), sel);
        char *rt = QQRPReturnTypeCopy(m);
        BOOL ok = (rt && rt[0] == '@');
        free(rt);
        if (ok) {
            id (*send)(id, SEL) = (id (*)(id, SEL))objc_msgSend;
            @try { return send(obj, sel); } @catch (NSException *e) {}
        }
    }
    @try { return [obj valueForKey:name]; } @catch (NSException *e) {}
    return nil;
}

static id QQRPValueForKey(id obj, NSString *key) {
    if (!obj || key.length == 0) return nil;
    if (![(id)obj isKindOfClass:[NSObject class]]) return nil;
    @try { return [obj valueForKey:key]; } @catch (NSException *e) {}
    return nil;
}

// 标量 int 读取 (chatType 这类标量: 第一参数是 int, 必然不能用 id 调!)
__attribute__((unused)) static NSInteger QQRPIntForKey(id obj, NSString *key) {
    if (!obj || key.length == 0) return 0;
    if (![(id)obj isKindOfClass:[NSObject class]]) return 0;
    SEL sel = NSSelectorFromString(key);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    char *rts = QQRPReturnTypeCopy(m);
    char c0 = rts ? rts[0] : 0;
    free(rts);
    if (m && c0 && c0 != '@') {
        // 标量整型才允许寄存器读 (i/I/l/L/q/Q/s/S/c/C/B); 浮点返回在 v 寄存器, 不能这样调
        if (c0 == 'i' || c0 == 'I' || c0 == 'l' || c0 == 'L' || c0 == 'q' || c0 == 'Q' ||
            c0 == 's' || c0 == 'S' || c0 == 'c' || c0 == 'C' || c0 == 'B') {
            long long (*send)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
            @try { return (NSInteger)send(obj, sel); } @catch (NSException *e) {}
        }
        return 0;
    }
    id out = QQRPCallObjectGetter(obj, sel);
    if (out && [out isKindOfClass:[NSNumber class]]) return [(NSNumber *)out integerValue];
    return 0;
}

// long long 读取 (msgId/msgSeq)
static long long QQRPLongLongForKey(id obj, NSString *key) {
    if (!obj || key.length == 0) return 0;
    if (![(id)obj isKindOfClass:[NSObject class]]) return 0;
    SEL sel = NSSelectorFromString(key);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    char *rts = QQRPReturnTypeCopy(m);
    char c0 = rts ? rts[0] : 0;
    free(rts);
    if (m && c0 && c0 != '@') {
        if (c0 == 'i' || c0 == 'I' || c0 == 'l' || c0 == 'L' || c0 == 'q' || c0 == 'Q' ||
            c0 == 's' || c0 == 'S' || c0 == 'c' || c0 == 'C' || c0 == 'B') {
            long long (*send)(id, SEL) = (long long (*)(id, SEL))objc_msgSend;
            @try { return send(obj, sel); } @catch (NSException *e) {}
        }
        return 0;
    }
    if (m && c0 == '@') {
        id out = QQRPCallObjectGetter(obj, sel);
        if (out && [out isKindOfClass:[NSNumber class]]) return [(NSNumber *)out longLongValue];
        if (out && [out isKindOfClass:[NSString class]]) return [(NSString *)out longLongValue];
        return 0;
    }
    @try {
        id out = [obj valueForKey:key];
        if (out && [out isKindOfClass:[NSNumber class]]) return [(NSNumber *)out longLongValue];
        if (out && [out isKindOfClass:[NSString class]]) return [(NSString *)out longLongValue];
    } @catch (NSException *e) {}
    return 0;
}

// NSString 读取 (peerUid/guildId)
static NSString *QQRPStringForKey(id obj, NSString *key) {
    if (!obj || key.length == 0) return nil;
    if (![(id)obj isKindOfClass:[NSObject class]]) return nil;
    SEL sel = NSSelectorFromString(key);
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    char *rts = QQRPReturnTypeCopy(m);
    BOOL isObj = (rts && rts[0] == '@');
    free(rts);
    if (m && isObj) {
        id out = QQRPCallObjectGetter(obj, sel);
        if (out && [out isKindOfClass:[NSString class]]) return out;
        return nil;
    }
    @try {
        id out = [obj valueForKey:key];
        if (out && [out isKindOfClass:[NSString class]]) return out;
    } @catch (NSException *e) {}
    return nil;
}

// ================= record 判定 =================

static BOOL QQRPLooksLikeRecord(id obj) {
    if (!obj) return NO;
    SEL s1 = NSSelectorFromString(@"msgId");
    SEL s2 = NSSelectorFromString(@"msgSeq");
    SEL s3 = NSSelectorFromString(@"peerUid");
    SEL s4 = NSSelectorFromString(@"msgType");
    return [obj respondsToSelector:s1] && [obj respondsToSelector:s2] &&
           [obj respondsToSelector:s3] && [obj respondsToSelector:s4];
}

// QQNT 中部分包装层把 record 藏在 msgId/msgSeq 类的 ivar 链更深层
// QQRPFindRecordDeep: 广度优先遍历 obj 对象图, 在 14 个候选 ivar 名里逐个找 record
// 深度上限 4, visited NSValue(指针) 去重, 复合容器(NSArray/NSDictionary) 个数 <= 6 才下钻

static id QQRPFindRecordDeep(id obj, int depth, NSMutableSet *visited) {
    if (!obj || depth > 4) return nil;
    if (![(id)obj isKindOfClass:[NSObject class]]) return nil;
    if (QQRPLooksLikeRecord(obj)) return obj;

    NSValue *ptr = [NSValue valueWithPointer:(__bridge void *)obj];
    if ([visited containsObject:ptr]) return nil;
    [visited addObject:ptr];

    // 原版 skip 的基础类型必须排除 (valueForKey 误剖字符串/数组)
    if ([obj isKindOfClass:[NSString class]]) return nil;
    if ([obj isKindOfClass:[NSNumber class]]) return nil;
    if ([obj isKindOfClass:[NSValue class]]) return nil;
    if ([obj isKindOfClass:[NSDate class]]) return nil;
    if ([obj isKindOfClass:[NSData class]]) return nil;
    if ([obj isKindOfClass:[NSURL class]]) return nil;

    if ([obj isKindOfClass:[NSArray class]]) {
        if ([obj count] > 6) return nil;
        for (id e in obj) {
            id r = QQRPFindRecordDeep(e, depth + 1, visited);
            if (r) return r;
        }
        return nil;
    }
    if ([obj isKindOfClass:[NSDictionary class]]) {
        if ([obj count] > 6) return nil;
        for (id v in [obj allValues]) {
            id r = QQRPFindRecordDeep(v, depth + 1, visited);
            if (r) return r;
        }
        return nil;
    }

    static NSArray *kNames = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kNames = @[@"viewModel", @"record", @"msgRecord", @"_record",
                   @"msg", @"message", @"msgData", @"messageModel",
                   @"contentVM", @"contentViewModel", @"cellViewModel",
                   @"cellModel", @"dataModel", @"model"];
    });
    for (NSString *key in kNames) {
        id val = QQRPSafeIvar(obj, key);
        if (val && val != obj) {
            id r = QQRPFindRecordDeep(val, depth + 1, visited);
            if (r) return r;
        }
    }
    return nil;
}

static id QQRPFindRecord(id obj) {
    if (!obj) return nil;
    NSMutableSet *visited = [NSMutableSet set];
    return QQRPFindRecordDeep(obj, 0, visited);
}

// ================= record 读取 (cell 内容视图 -> record) =================

// QQRPDirectRecordFromCell 顺序 (严格对应原版反汇编):
//   1) QQRPSafeIvar(view, "viewModel")            -> QQRPFindRecord
//   2) QQRPValueForKey(view, "viewModel")         -> QQRPFindRecord
//   3) QQRPSafeIvar(view, "tailContainerView")    -> 若有:
//        3a) QQRPSafeIvar(tv, "viewModel")        -> QQRPFindRecord
//        3b) QQRPValueForKey(tv, "viewModel")     -> QQRPFindRecord
//        3c) QQRPSafeIvar(tv, "record")           -> LooksLikeRecord ? 直接返回
//   4) QQRPSafeIvar(view, "content")              -> 若有:
//        4a) QQRPSafeIvar(content, "viewModel")   -> FindRecord / 或直接判定
static id QQRPDirectRecordFromCell(UIView *view) {
    if (!view) return nil;

    // 1)
    id vm = QQRPSafeIvar(view, @"viewModel");
    if (vm) {
        id r = QQRPFindRecord(vm);
        if (QQRPLooksLikeRecord(r)) return r;
    }
    // 2)
    vm = QQRPValueForKey(view, @"viewModel");
    if (vm) {
        id r = QQRPFindRecord(vm);
        if (QQRPLooksLikeRecord(r)) return r;
    }

    // 3) tailContainerView
    id tv = QQRPSafeIvar(view, @"tailContainerView");
    if (!tv) tv = QQRPValueForKey(view, @"tailContainerView");
    if (tv) {
        id vm2 = QQRPSafeIvar(tv, @"viewModel");
        if (!vm2) vm2 = QQRPValueForKey(tv, @"viewModel");
        if (vm2) {
            id r = QQRPFindRecord(vm2);
            if (QQRPLooksLikeRecord(r)) return r;
        }
        id rr = QQRPSafeIvar(tv, @"record");
        if (QQRPLooksLikeRecord(rr)) return rr;
        rr = QQRPFindRecord(rr);
        if (QQRPLooksLikeRecord(rr)) return rr;
    }

    // 4) content
    id ct = QQRPSafeIvar(view, @"content");
    if (ct) {
        id vm3 = QQRPSafeIvar(ct, @"viewModel");
        if (!vm3) vm3 = QQRPValueForKey(ct, @"viewModel");
        id r = QQRPFindRecord(vm3);
        if (QQRPLooksLikeRecord(r)) return r;
    }
    return nil;
}

// QQRPRecordForCell(view) — view 即被 hook 的 NTAIOCellView 系 cell 内容视图:
//   先直接判 view 本身 (原版再把 record 缓存到 view 上; 这版不做缓存, 规避复用错位)
static id QQRPRecordForCell(UIView *view) {
    if (!QQRPEnabled()) return nil;
    if (!view) return nil;

    id r = QQRPDirectRecordFromCell(view);
    if (r && QQRPLooksLikeRecord(r)) return r;

    // 最后兜底: 整个 view 的对象图搜索 (原版最后一层也这么干)
    r = QQRPFindRecord(view);
    if (r && QQRPLooksLikeRecord(r)) return r;
    return nil;
}

// ================= contact =================

// record.contact 有则直接用(若对象类型@); 否则用
//   [OCContact ContactWithChatType:<int标量> peerUid:<NSString> guildId:<NSString 可 nil>]
static id QQRPContactForRecord(id record) {
    if (!record) return nil;
    id contact = QQRPCallObjectGetter(record, NSSelectorFromString(@"contact"));
    if ([contact isKindOfClass:[NSObject class]]) return contact;
    contact = QQRPValueForKey(record, @"contact");
    if ([contact isKindOfClass:[NSObject class]]) return contact;

    NSInteger chatType = (NSInteger)QQRPLongLongForKey(record, @"chatType");
    NSString *peerUid = QQRPStringForKey(record, @"peerUid");
    if (!peerUid || peerUid.length == 0) return nil;
    NSString *guildId = QQRPStringForKey(record, @"guildId");

    Class OCContact = objc_getClass("OCContact");
    if (!OCContact) return nil;
    SEL sel = NSSelectorFromString(@"ContactWithChatType:peerUid:guildId:");
    if (![OCContact respondsToSelector:sel]) return nil;
    // 第二参数是标量 int !! 不能声明为 id.
    id (*fn)(Class, SEL, int, id, id) = (id (*)(Class, SEL, int, id, id))objc_msgSend;
    id out = fn(OCContact, sel, (int)chatType, peerUid, guildId);
    return out;
}

// ================= kernel service =================

// svc = [QSLManager getInstance].msgService (原版经静态槽缓存; 这里每次现取, 开销可忽略)
static id QQRPKernelService(void) {
    Class QSLMgr = objc_getClass("QSLManager");
    if (!QSLMgr) return nil;
    SEL sGet = NSSelectorFromString(@"getInstance");
    if (![QSLMgr respondsToSelector:sGet]) return nil;
    id inst = ((id (*)(id, SEL))objc_msgSend)((id)QSLMgr, sGet);
    if (!inst) return nil;
    if (![inst respondsToSelector:NSSelectorFromString(@"msgService")]) return nil;
    return QQRPCallObjectGetter(inst, NSSelectorFromString(@"msgService"));
}

// ================= msgId (标量/对象自适应) =================

static long long QQRPMsgIdOf(id record) {
    if (!record) return 0;
    return QQRPLongLongForKey(record, @"msgId");
}

// ================= 复读主体 =================

static double QQRPNow(void) {
    return [NSDate timeIntervalSinceReferenceDate];
}

static double gLastRepeatTime = 0.0;
static NSString *gLastRepeatIdentity = nil;

static NSString *QQRPIdentityForRecord(id record) {
    if (!record) return nil;
    long long msgId   = QQRPLongLongForKey(record, @"msgId");
    long long msgSeq  = QQRPLongLongForKey(record, @"msgSeq");
    NSString *peerUid = QQRPStringForKey(record, @"peerUid");
    if (!peerUid) peerUid = @"";
    return [NSString stringWithFormat:@"%@/%lld/%lld", peerUid, msgSeq, msgId];
}

static void QQRPRepeatRecord(id record) {
    @try {
        if (!QQRPEnabled()) return;
        if (!record) return;
        if (!QQRPLooksLikeRecord(record)) return;

        long long msgId = QQRPMsgIdOf(record);
        if (msgId <= 0) {
            QQRPLog(@"repeat abort: msgId<=0 record=%@ [%@]", object_getClass(record), QQRPClassStr(record));
            return;
        }

        NSString *identity = QQRPIdentityForRecord(record);
        double now = QQRPNow();
        if (identity && gLastRepeatIdentity &&
            [identity isEqualToString:gLastRepeatIdentity] && (now - gLastRepeatTime) < 0.65) {
            QQRPLog(@"repeat skip throttle: %@", identity);
            return;
        }
        gLastRepeatTime = now;
        gLastRepeatIdentity = identity ?: @"";

        // 允许复读自己发的消息 —— 原版有 [AIODefine.MsgSendTypeUtil shoudldSelfSendMsgWithRecord:]
        // 拦截, 这里去掉以满足"自己消息也能双击复读"的要求.

        id svc = QQRPKernelService();
        id contact = QQRPContactForRecord(record);
        if (!svc || !contact) {
            QQRPLog(@"repeat abort: svc=%@ contact=%@ record=%@", svc ? QQRPClassStr(svc) : @"nil",
                    contact ? QQRPClassStr(contact) : @"nil", QQRPClassStr(record));
            return;
        }

        id msgs  = @[[NSNumber numberWithLongLong:msgId]];
        id dsts  = @[contact];
        SEL sForward = NSSelectorFromString(@"forwardMsg:srcContact:dstContacts:msgAttributeInfos:cb:");
        if (![svc respondsToSelector:sForward]) {
            QQRPLog(@"repeat abort: svc %@ no forwardMsg", QQRPClassStr(svc));
            return;
        }
        void (*fwd)(id, SEL, id, id, id, id, id) = (void (*)(id, SEL, id, id, id, id, id))objc_msgSend;
        fwd(svc, sForward, msgs, contact, dsts, (id)nil, (id)nil);
        QQRPLog(@"repeat forwarded: %@ msgId=%lld", QQRPClassStr(record), msgId);
    } @catch (NSException *e) {
        QQRPLog(@"repeat exception: %@ (%@)", e.name, e.reason);
    }
}

// ================= 从 cell / 视图解析 record =================

// 从任意 view 起, 尝试常见路径取 record:
// 1) 自身/子视图的 viewModel -> FindRecord
// 2) UITableViewCell: contentView 子树(深度<=4) 里找带 viewModel 的视图
// 3) 兜底 BFS
static id QQRPRecordFromViewShallow(UIView *v, int depth) {
    if (!v || depth > 4) return nil;
    id vm = QQRPSafeIvar(v, @"viewModel");
    if (!vm) vm = QQRPValueForKey(v, @"viewModel");
    if (vm) {
        id r = QQRPFindRecord(vm);
        if (QQRPLooksLikeRecord(r)) return r;
    }
    id rr = QQRPSafeIvar(v, @"record");
    if (!QQRPLooksLikeRecord(rr)) rr = QQRPValueForKey(v, @"record");
    if (QQRPLooksLikeRecord(rr)) return rr;
    for (UIView *sub in v.subviews) {
        id r = QQRPRecordFromViewShallow(sub, depth + 1);
        if (r) return r;
    }
    return nil;
}

static id QQRPRecordFromCellOrView(UIView *view) {
    if (!view) return nil;
    id r = QQRPRecordFromViewShallow(view, 0);
    if (r) return r;
    UIView *v = view;
    for (int i = 0; i < 10 && v; ++i, v = v.superview) {
        if ([v isKindOfClass:[UITableViewCell class]]) {
            r = QQRPRecordFromViewShallow(((UITableViewCell *)v).contentView, 0);
            if (r) return r;
        }
    }
    r = QQRPFindRecord(view);
    if (QQRPLooksLikeRecord(r)) return r;
    return nil;
}

// ================= 手势 target =================

@interface QQRepeaterGestureTarget : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *lastTouchView;
+ (instancetype)shared;
- (void)doubleTap:(UITapGestureRecognizer *)gr;
@end

@implementation QQRepeaterGestureTarget
+ (instancetype)shared {
    static QQRepeaterGestureTarget *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [QQRepeaterGestureTarget new]; });
    return shared;
}

// 热路径: 只记录 touch.view 弱引用, 不做任何自省
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    if (!QQRPEnabled()) return NO;
    self.lastTouchView = t.view;
    return YES;
}

// 允许其他手势 (长按/点击) 同时工作
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g
shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)o {
    return YES;
}

- (void)doubleTap:(UITapGestureRecognizer *)gr {
    @try {
        if (!QQRPEnabled()) return;
        if (gr.state != UIGestureRecognizerStateEnded) return;

        UIView *hostView = gr.view;
        UIView *hit = self.lastTouchView;

        UITableView *table = nil;
        if ([hostView isKindOfClass:[UITableView class]]) {
            table = (UITableView *)hostView;
        } else if (hit) {
            UIView *v = hit;
            while (v && ![v isKindOfClass:[UITableView class]]) v = v.superview;
            if ([v isKindOfClass:[UITableView class]]) table = (UITableView *)v;
        }

        UITableViewCell *cell = nil;
        NSIndexPath *ip = nil;
        if (table) {
            CGPoint p = hit ? [hit convertPoint:CGPointZero toView:table] : [gr locationInView:table];
            ip = [table indexPathForRowAtPoint:p];
            if (ip) cell = [table cellForRowAtIndexPath:ip];
        }

        QQRPLog(@"doubleTap table=%@ ip=%@ cell=%@ hit=%@",
                QQRPClassStr(table), ip, QQRPClassStr(cell), QQRPClassStr(hit));

        id record = cell ? QQRPRecordFromCellOrView(cell) : nil;
        if (!record) record = QQRPRecordFromCellOrView(hit);
        if (!record) {
            QQRPLog(@"record miss (cell=%@ hit=%@)", QQRPClassStr(cell), QQRPClassStr(hit));
            return;
        }
        QQRPLog(@"record=%@ msgId=%lld", QQRPClassStr(record), QQRPMsgIdOf(record));
        QQRPRepeatRecord(record);
    } @catch (NSException *e) {
        QQRPLog(@"doubleTap exception: %@ (%@)", e.name, e.reason);
    }
}
@end

// ================= 手势安装 =================

// key 之一: 手势是否已装
static void *kQQRPGestureInstalled = &kQQRPGestureInstalled;

static void QQRPEnsureGesture(UIView *view) {
    if (!view || !QQRPEnabled()) return;
    if (objc_getAssociatedObject(view, kQQRPGestureInstalled)) return;
    QQRepeaterGestureTarget *t = [QQRepeaterGestureTarget shared];
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(doubleTap:)];
    if (!g) return;
    g.numberOfTapsRequired = 2;
    g.numberOfTouchesRequired = 1;
    g.cancelsTouchesInView = NO;
    g.delaysTouchesBegan = NO;
    g.delaysTouchesEnded = NO;
    g.delegate = t;
    [view addGestureRecognizer:g];
    objc_setAssociatedObject(view, kQQRPGestureInstalled, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ================= cell 类扫描 & hook =================

// NTAIOCellView 及其子孙类 hook 后由 layoutSubviews 触发 RPEnsureGesture.
// hook 方式: class_copyMethodList 找"自有的 layoutSubviews"(否则跳过),
// 存原 IMP, method_setImplementation 换成我们的 block, block 内先调原版再装手势。

static IMP QQRPGetOwnIMP(Class cls, SEL sel) {
    if (!cls || !sel) return NULL;
    unsigned int cnt = 0;
    Method *list = class_copyMethodList(cls, &cnt);
    IMP imp = NULL;
    for (unsigned int i = 0; i < cnt; ++i) {
        if (method_getName(list[i]) == sel) {
            imp = method_getImplementation(list[i]);
            break;
        }
    }
    free(list);
    return imp;
}

typedef void (*QQRPOrigLayoutSubviews)(id, SEL);

static IMP QQRPLayoutSubviewsOrigIMPFor(Class cls) {
    return QQRPGetOwnIMP(cls, NSSelectorFromString(@"layoutSubviews"));
}

// 已 hook 的类用 NSMutableSet 记住, 防重复
static NSMutableSet *gQQRPHookedClasses = nil;

static void QQRPHookCellClass(Class cls) {
    if (!cls) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gQQRPHookedClasses = [NSMutableSet set]; });
    NSString *clsName = NSStringFromClass(cls);
    if (!clsName || [gQQRPHookedClasses containsObject:clsName]) return;

    IMP orig = QQRPLayoutSubviewsOrigIMPFor(cls);
    if (!orig) return; // 没自有 layoutSubviews, 不 hook (避免破坏父类行为)

    SEL sel = NSSelectorFromString(@"layoutSubviews");
    // block 签名必须与被 hook 方法一致: (id self, SEL _cmd)
    void (^blk)(id, SEL) = ^(id selfSelf, SEL cmdSelf) {
        @try {
            ((void (*)(id, SEL))orig)(selfSelf, cmdSelf);
        } @catch (NSException *e) {
            QQRPLog(@"layoutSubviews orig exception %@", e.name);
        }
        @try {
            if (QQRPEnabled()) {
                QQRPEnsureGesture((UIView *)selfSelf);
            }
        } @catch (NSException *e) {
            QQRPLog(@"layoutSubviews hook exception %@", e.name);
        }
    };
    IMP newImp = imp_implementationWithBlock(blk);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) return;
    method_setImplementation(m, newImp);
    [gQQRPHookedClasses addObject:clsName];
    QQRPLog(@"hook cell class %@", clsName);
}

// 找基类 -> 子孙判定
static BOOL QQRPClassIsDescendant(Class cls, Class base) {
    if (!cls || !base) return NO;
    for (Class c = cls; c; c = class_getSuperclass(c)) {
        if (c == base) return YES;
    }
    return NO;
}

// QQRPInstallInheritedLayout("NTAIOCellView")
static void QQRPInstallInheritedLayout(const char *name) {
    Class cls = objc_getClass(name);
    if (!cls) {
        QQRPLog(@"installInheritedLayout: class %s 不存在", name);
        return;
    }
    QQRPHookCellClass(cls);
}

// QQRPScanUI —— 不再硬依赖某个基类: 扫全部类名里带 AIO/CellView/NTAIOCell 的 UIView 子类
static void QQRPScanUI(void) {
    @try {
        if (!QQRPEnabled()) return;
        QQRPInstallInheritedLayout("NTAIOCellView");

        Class b1 = objc_getClass("NTBaseAIO.NTAIOBaseCellView");
        Class b2 = objc_getClass("NTAIOBaseCellView");
        Class b3 = objc_getClass("NTAIOCellView");
        QQRPLog(@"scanUI bases: NTBaseAIO.NTAIOBaseCellView=%@ NTAIOBaseCellView=%@ NTAIOCellView=%@",
                b1 ? @"Y" : @"N", b2 ? @"Y" : @"N", b3 ? @"Y" : @"N");

        unsigned int count = 0;
        Class *list = objc_copyClassList(&count);
        if (!list || !count) return;
        int matched = 0;
        for (unsigned int i = 0; i < count; i++) {
            Class c = list[i];
            if (!c) continue;
            NSString *nm = NSStringFromClass(c);
            if (!nm || nm.length == 0) continue;
            BOOL related = [nm containsString:@"AIO"] || [nm containsString:@"CellView"] ||
                           [nm containsString:@"NTAIOCell"] || [nm containsString:@"ChatCell"];
            if (!related) continue;
            if (![c isSubclassOfClass:[UIView class]]) continue;
            matched++;
            if (matched <= 40) QQRPLog(@"candidate[%d] %@", matched, nm);
            QQRPHookCellClass(c);
        }
        QQRPLog(@"scanUI done classes=%u matched=%d", count, matched);
        free(list);
    } @catch (NSException *e) {
        QQRPLog(@"scanUI exception %@ (%@)", e.name, e.reason);
    }
}

// 挂手势到 root 下所有 UITableView (只挂一次/表)
static void QQRPAttachToTables(UIView *root) {
    if (!root) return;
    NSMutableArray *stack = [NSMutableArray arrayWithObject:root];
    int n = 0, tables = 0;
    while (stack.count && n < 3000) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        n++;
        if ([v isKindOfClass:[UITableView class]]) {
            QQRPEnsureGesture(v);
            tables++;
            continue;
        }
        for (UIView *sub in v.subviews) [stack addObject:sub];
    }
    if (tables > 0) QQRPLog(@"attachToTables: %d tables under %@", tables, QQRPClassStr(root));
}

// ================= UIViewController viewDidAppear hook =================

static double gLastVCAppearAt = 0.0;

static void QQRPHookViewControllerViewDidAppear(void) {
    Class vc = objc_getClass("UIViewController");
    if (!vc) return;
    SEL sel = NSSelectorFromString(@"viewDidAppear:");
    Method m = class_getInstanceMethod(vc, sel);
    if (!m) return;
    IMP orig = method_getImplementation(m);
    if (!orig) return;
    void (^blk)(id, SEL, BOOL) = ^(id selfSelf, SEL cmdSelf, BOOL anim) {
        @try {
            ((void (*)(id, SEL, BOOL))orig)(selfSelf, cmdSelf, anim);
        } @catch (NSException *e) {
            QQRPLog(@"viewDidAppear orig exception %@", e.name);
        }
        @try {
            if (!QQRPEnabled()) return;
            NSString *nm = NSStringFromClass(object_getClass(selfSelf));
            // 不做类名筛选: 任何 VC 出现时都找一下 UITableView, 只挂表(有 assoc 去重)
            UIView *root = [(UIViewController *)selfSelf view];
            if (root) QQRPAttachToTables(root);
            double now = QQRPNow();
            if (gLastVCAppearAt == 0.0 || (now - gLastVCAppearAt) > 2.0) {
                gLastVCAppearAt = now;
                if (nm) QQRPLog(@"vc appeared: %@", nm);
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try { QQRPScanUI(); } @catch (NSException *e) {
                        QQRPLog(@"scanUI after exception %@", e.name);
                    }
                });
            }
        } @catch (NSException *e) {
            QQRPLog(@"viewDidAppear hook exception %@", e.name);
        }
    };
    method_setImplementation(m, imp_implementationWithBlock(blk));
    QQRPLog(@"hooked UIViewController.viewDidAppear:");
}

// ================= 入口 =================

static void QQRPInstallOnce(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        QQRPLog(@"QQRepeatOnly %@ init (fresh-build)", QQRP_VERSION);
        QQRPHookViewControllerViewDidAppear();
        // 启动后多轮扫描: 类可能在框架懒加载后才出现
        for (int i = 1; i <= 6; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(i * 1.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try { QQRPScanUI(); } @catch (NSException *e) {
                    QQRPLog(@"startup scanUI exception %@", e.name);
                }
            });
        }
    });
}

__attribute__((constructor)) static void QQRepeatOnlyEntry(void) {
    // 延迟主线程挂 hook, 避免抢占 link 时序
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        QQRPInstallOnce();
    });
}
