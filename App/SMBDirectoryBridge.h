#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// The kind of an item returned by an SMB directory listing.
typedef NS_ENUM(NSInteger, RNGSMBDirectoryItemType) {
    RNGSMBDirectoryItemTypeUnknown = 0,
    RNGSMBDirectoryItemTypeFile,
    RNGSMBDirectoryItemTypeDirectory,
};

/// Errors intentionally contain only product-safe, generic descriptions.
typedef NS_ENUM(NSInteger, RNGSMBDirectoryBridgeErrorCode) {
    RNGSMBDirectoryBridgeErrorInvalidURL = 1,
    RNGSMBDirectoryBridgeErrorUnsupportedDomain,
    RNGSMBDirectoryBridgeErrorUnavailable,
    RNGSMBDirectoryBridgeErrorAuthentication,
    RNGSMBDirectoryBridgeErrorTimeout,
    RNGSMBDirectoryBridgeErrorCancelled,
    RNGSMBDirectoryBridgeErrorItemLimit,
    RNGSMBDirectoryBridgeErrorFailed,
};

FOUNDATION_EXPORT NSErrorDomain const RNGSMBDirectoryBridgeErrorDomain;

/// An immutable, URL-only snapshot of one directory entry.
///
/// The bridge never returns credentials in either the URL or the name. The
/// caller must perform any same-share and path-policy checks before presenting
/// or opening the item.
@interface RNGSMBDirectoryItem : NSObject

@property(nonatomic, readonly, copy) NSString *name;
/// Alias retained for callers that use the explicit itemURL terminology.
@property(nonatomic, readonly, copy) NSURL *itemURL;
@property(nonatomic, readonly, copy) NSURL *url;
@property(nonatomic, readonly) RNGSMBDirectoryItemType type;
@property(nonatomic, readonly, getter=isDirectory) BOOL directory;

- (instancetype)init NS_UNAVAILABLE;

@end

/// The completion is invoked exactly once on the main queue. It receives
/// either a nonnull item array and nil error, or nil items and a generic
/// NSError from RNGSMBDirectoryBridgeErrorDomain.
typedef void (^RNGSMBDirectoryCompletion)(
    NSArray<RNGSMBDirectoryItem *> *_Nullable items,
    NSError *_Nullable error);

/// A cancellation handle for one asynchronous directory request.
@interface RNGSMBDirectoryRequest : NSObject

@property(nonatomic, readonly, getter=isCancelled) BOOL cancelled;

- (void)cancel;

@end

/// Asynchronous SMB directory listing through the public LibVLC C API.
///
/// The implementation owns a separate LibVLC instance and serial worker
/// queue. It does not use TVVLCKit's private libsmb2 symbols. Credentials are
/// supplied only to the transient LibVLC dialog callback and are never stored
/// by LibVLC (the callback always answers with b_store=false).
/// Completion callbacks are always delivered exactly once on the main queue,
/// including validation failures and cancellation.
@interface RNGSMBDirectoryBridge : NSObject

- (instancetype)init;

/// `domain` is rejected when nonempty because the public LibVLC dialog API
/// exposes no domain field. The bridge never guesses a private SMB option.
- (RNGSMBDirectoryRequest *)listDirectoryAtURL:(NSURL *)url
                                       username:(nullable NSString *)username
                                       password:(nullable NSString *)password
                                         domain:(nullable NSString *)domain
                                     completion:(RNGSMBDirectoryCompletion)completion
    NS_SWIFT_NAME(listDirectory(at:username:password:domain:completion:));

/// Cancels all requests that have not completed. Completion callbacks still
/// arrive once, with RNGSMBDirectoryBridgeErrorCancelled where applicable.
- (void)cancelAllRequests;

@end

NS_ASSUME_NONNULL_END
