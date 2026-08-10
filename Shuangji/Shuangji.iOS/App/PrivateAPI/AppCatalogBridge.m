#import "AppCatalogBridge.h"
#import "LSApplicationWorkspace.h"
#import "LSApplicationProxy.h"
#import <objc/message.h>
#import <objc/runtime.h>

static NSDictionary *SYDictFromProxy(id proxy) {
    if (proxy == nil) return nil;

    SEL idSel = @selector(applicationIdentifier);
    SEL urlSel = @selector(bundleURL);
    if (![proxy respondsToSelector:idSel] || ![proxy respondsToSelector:urlSel]) return nil;

    NSString *bid = ((NSString *(*)(id, SEL))objc_msgSend)(proxy, idSel);
    NSURL *url = ((NSURL *(*)(id, SEL))objc_msgSend)(proxy, urlSel);
    if (bid.length == 0 || url == nil) return nil;

    NSString *name = bid;
    if ([proxy respondsToSelector:@selector(localizedName)]) {
        NSString *n = ((NSString *(*)(id, SEL))objc_msgSend)(proxy, @selector(localizedName));
        if (n.length) name = n;
    }

    NSString *ver = @"";
    if ([proxy respondsToSelector:@selector(shortVersionString)]) {
        NSString *v = ((NSString *(*)(id, SEL))objc_msgSend)(proxy, @selector(shortVersionString));
        if (v) ver = v;
    }

    NSString *type = @"User";
    if ([proxy respondsToSelector:@selector(applicationType)]) {
        NSString *t = ((NSString *(*)(id, SEL))objc_msgSend)(proxy, @selector(applicationType));
        if (t.length) type = t;
    }

    NSString *team = @"";
    if ([proxy respondsToSelector:@selector(teamID)]) {
        NSString *t = ((NSString *(*)(id, SEL))objc_msgSend)(proxy, @selector(teamID));
        if (t.length) team = t;
    }

    return @{
        @"bundleID": bid,
        @"name": name,
        @"version": ver,
        @"bundlePath": url.path ?: @"",
        @"appType": type,
        @"teamID": team,
    };
}

static void SYAppendProxies(NSArray *proxies, NSMutableDictionary *byID) {
    for (id obj in proxies) {
        NSDictionary *d = SYDictFromProxy(obj);
        if (!d) continue;
        NSString *bid = d[@"bundleID"];
        if (bid.length) byID[bid] = d;
    }
}

NSArray<NSDictionary *> *SYFetchInstalledApplications(void) {
    NSMutableDictionary *byID = [NSMutableDictionary dictionary];

    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsCls) return @[];

    SEL defSel = @selector(defaultWorkspace);
    if (![wsCls respondsToSelector:defSel]) return @[];
    id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel);
    if (!ws) return @[];

    if ([ws respondsToSelector:@selector(allApplications)]) {
        NSArray *all = ((NSArray *(*)(id, SEL))objc_msgSend)(ws, @selector(allApplications));
        if ([all isKindOfClass:[NSArray class]]) {
            SYAppendProxies(all, byID);
        }
    }

    if (byID.count == 0 && [ws respondsToSelector:@selector(allInstalledApplications)]) {
        NSArray *all = ((NSArray *(*)(id, SEL))objc_msgSend)(ws, @selector(allInstalledApplications));
        if ([all isKindOfClass:[NSArray class]]) {
            SYAppendProxies(all, byID);
        }
    }

    if (byID.count == 0 && [ws respondsToSelector:@selector(enumerateApplicationsOfType:block:)]) {
        void (^block)(id) = ^(id proxy) {
            NSDictionary *d = SYDictFromProxy(proxy);
            if (!d) return;
            NSString *bid = d[@"bundleID"];
            if (bid.length) byID[bid] = d;
        };
        for (NSInteger t = 0; t <= 1; t++) {
            ((void (*)(id, SEL, NSInteger, id))objc_msgSend)(
                ws, @selector(enumerateApplicationsOfType:block:), t, block);
        }
    }

    return byID.allValues ?: @[];
}

BOOL SYOpenApplicationWithBundleID(NSString *bundleID) {
    if (bundleID.length == 0) return NO;
    Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
    if (!wsCls) return NO;
    SEL defSel = @selector(defaultWorkspace);
    if (![wsCls respondsToSelector:defSel]) return NO;
    id ws = ((id (*)(id, SEL))objc_msgSend)(wsCls, defSel);
    if (!ws) return NO;
    SEL openSel = @selector(openApplicationWithBundleID:);
    if (![ws respondsToSelector:openSel]) return NO;
    return ((BOOL (*)(id, SEL, id))objc_msgSend)(ws, openSel, bundleID);
}
