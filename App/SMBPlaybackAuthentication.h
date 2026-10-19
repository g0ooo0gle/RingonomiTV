#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class VLCLibrary;

/// Supplies one transient SMB credential set to a dedicated TVVLCKit player.
///
/// The object owns its dialog provider until it is retired with the player.
/// Calling `invalidate` disables further responses and clears the in-memory
/// credential copy.  A nil username represents guest access.  SMB domain
/// authentication is intentionally not part of this transient API.
@interface RNGSMBPlaybackAuthentication : NSObject

- (nullable instancetype)initWithLibrary:(VLCLibrary *)library
                                 username:(nullable NSString *)username
                                 password:(nullable NSString *)password
    NS_DESIGNATED_INITIALIZER;

- (void)invalidate;

- (instancetype)init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
