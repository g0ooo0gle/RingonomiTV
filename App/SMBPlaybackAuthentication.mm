#import "SMBPlaybackAuthentication.h"

#import <TVVLCKit/VLCDialogProvider.h>
#import <TVVLCKit/VLCLibrary.h>

#include <atomic>
#include <cstddef>
#include <cstring>
#include <mutex>
#include <string>
#include <utility>

namespace {

constexpr std::size_t kMaximumUsernameBytes = 512;
constexpr std::size_t kMaximumPasswordBytes = 4 * 1024;

std::string UTF8Credential(NSString *value, std::size_t maximumBytes) {
    if (value == nil) {
        return {};
    }

    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding
                         allowLossyConversion:NO];
    if (data == nil || data.length == 0 || data.length > maximumBytes ||
        std::memchr(data.bytes, '\0', data.length) != nullptr) {
        return {};
    }

    return std::string(static_cast<const char *>(data.bytes), data.length);
}

/// Wipe the best-effort transient C++ copy before releasing its allocation.
void ClearTransient(std::string &value) noexcept {
    volatile char *bytes = value.empty() ? nullptr : value.data();
    for (std::size_t index = 0; index < value.size(); ++index) {
        bytes[index] = 0;
    }
    value.clear();
    value.shrink_to_fit();
}

} // namespace

@interface RNGSMBPlaybackAuthentication () <VLCCustomDialogRendererProtocol>
@end

@implementation RNGSMBPlaybackAuthentication {
    std::mutex _stateMutex;
    std::atomic_bool _active;
    std::atomic_bool _loginAnswered;
    std::string _username;
    std::string _password;
    __strong VLCDialogProvider *_provider;
}

- (nullable instancetype)initWithLibrary:(VLCLibrary *)library
                                 username:(nullable NSString *)username
                                 password:(nullable NSString *)password {
    if (library == nil) {
        return nil;
    }

    self = [super init];
    if (self == nil) {
        return nil;
    }

    _active.store(false, std::memory_order_relaxed);
    _loginAnswered.store(false, std::memory_order_relaxed);

    std::string usernameBytes =
        UTF8Credential(username, kMaximumUsernameBytes);
    std::string passwordBytes;
    // A missing or invalid username is guest access.  Do not retain a
    // password supplied alongside it.
    if (!usernameBytes.empty()) {
        passwordBytes = UTF8Credential(password, kMaximumPasswordBytes);
    }

    {
        std::lock_guard<std::mutex> lock(_stateMutex);
        _username = std::move(usernameBytes);
        _password = std::move(passwordBytes);
    }

    VLCDialogProvider *provider =
        [[VLCDialogProvider alloc] initWithLibrary:library customUI:YES];
    if (provider == nil) {
        [self invalidate];
        return nil;
    }

    {
        std::lock_guard<std::mutex> lock(_stateMutex);
        _provider = provider;
        _active.store(true, std::memory_order_release);
    }

    // VLCDialogProvider deliberately keeps this renderer weak.  The owner of
    // this object must retain it for the lifetime of the dedicated player.
    provider.customRenderer = self;
    return self;
}

- (void)invalidate {
    @autoreleasepool {
        std::unique_lock<std::mutex> lock(_stateMutex);
        _active.store(false, std::memory_order_release);
        _loginAnswered.store(true, std::memory_order_release);

        // Keep the provider strongly owned until this object's player-retired
        // lifetime ends, but stop it from calling back into the renderer.
        if (_provider != nil) {
            _provider.customRenderer = nil;
        }

        ClearTransient(_username);
        ClearTransient(_password);
        // A callback that already began owns only its local transient copy.
        // It observes _active before posting, clears that copy, and returns.
        // Do not wait here: invalidate is called from the main actor during
        // stop/retry and must never block the UI thread on a VLC callback.
    }
}

- (void)showErrorWithTitle:(NSString *)title
                   message:(NSString *)message {
    // Never surface or log remote dialog text.  The caller reports a generic
    // SMB failure through its normal playback error path.
    (void)title;
    (void)message;
}

- (void)showLoginWithTitle:(NSString *)title
                   message:(NSString *)message
           defaultUsername:(nullable NSString *)defaultUsername
          askingForStorage:(BOOL)askingForStorage
             withReference:(NSValue *)reference {
    (void)title;
    (void)message;
    (void)defaultUsername;
    (void)askingForStorage;

    @autoreleasepool {
        VLCDialogProvider *provider = nil;
        std::string username;
        std::string password;
        bool shouldDismiss = false;

        {
            std::lock_guard<std::mutex> lock(_stateMutex);
            provider = _provider;
            if (!_active.load(std::memory_order_acquire) ||
                _loginAnswered.load(std::memory_order_acquire) ||
                _username.empty() || provider == nil) {
                shouldDismiss = true;
            } else {
                _loginAnswered.store(true, std::memory_order_release);
                username = _username;
                password = _password;
            }
        }

        if (shouldDismiss) {
            if (provider != nil) {
                [provider dismissDialogWithReference:reference];
            }
            return;
        }

        NSString *usernameValue =
            [[NSString alloc] initWithBytes:username.data()
                                     length:username.size()
                                   encoding:NSUTF8StringEncoding];
        NSString *passwordValue = password.empty()
            ? @""
            : [[NSString alloc] initWithBytes:password.data()
                                        length:password.size()
                                      encoding:NSUTF8StringEncoding];

        // The callback has exclusive ownership of this response slot.  The
        // provider is asked to avoid all persistent credential storage.
        if (provider != nil && usernameValue != nil && passwordValue != nil &&
            _active.load(std::memory_order_acquire)) {
            [provider postUsername:usernameValue
                       andPassword:passwordValue
                forDialogReference:reference
                             store:NO];
        } else if (provider != nil) {
            [provider dismissDialogWithReference:reference];
        }

        ClearTransient(username);
        ClearTransient(password);
        usernameValue = nil;
        passwordValue = nil;
    }
}

- (void)showQuestionWithTitle:(NSString *)title
                      message:(NSString *)message
                         type:(VLCDialogQuestionType)questionType
                 cancelString:(nullable NSString *)cancelString
                action1String:(nullable NSString *)action1String
                action2String:(nullable NSString *)action2String
                 withReference:(NSValue *)reference {
    (void)title;
    (void)message;
    (void)questionType;
    (void)cancelString;
    (void)action1String;
    (void)action2String;
    [self dismissDialogWithReference:reference];
}

- (void)showProgressWithTitle:(NSString *)title
                      message:(NSString *)message
              isIndeterminate:(BOOL)isIndeterminate
                     position:(float)position
                 cancelString:(nullable NSString *)cancelString
                 withReference:(NSValue *)reference {
    (void)title;
    (void)message;
    (void)isIndeterminate;
    (void)position;
    (void)cancelString;
    [self dismissDialogWithReference:reference];
}

- (void)updateProgressWithReference:(NSValue *)reference
                            message:(nullable NSString *)message
                            position:(float)position {
    (void)message;
    (void)position;
    [self dismissDialogWithReference:reference];
}

- (void)cancelDialogWithReference:(NSValue *)reference {
    (void)reference;
}

- (void)dismissDialogWithReference:(NSValue *)reference {
    if (reference == nil) {
        return;
    }

    VLCDialogProvider *provider = nil;
    {
        std::lock_guard<std::mutex> lock(_stateMutex);
        provider = _provider;
    }
    if (provider != nil) {
        [provider dismissDialogWithReference:reference];
    }
}

- (void)dealloc {
    // Do not dispatch cleanup to the main thread.  The player retirement
    // capsule may release this object from a worker thread, and the provider
    // has no UI-thread ownership requirement.
    [self invalidate];
}

@end
