#import "SMBDirectoryBridge.h"

#import <TVVLCKit/vlc/libvlc.h>
#import <TVVLCKit/vlc/libvlc_dialog.h>
#import <TVVLCKit/vlc/libvlc_media.h>
#import <TVVLCKit/vlc/libvlc_media_list.h>
#import <TVVLCKit/vlc/libvlc_picture.h>
#import <TVVLCKit/vlc/libvlc_events.h>

#import <dispatch/dispatch.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <utility>

@interface RNGSMBDirectoryItem ()
- (instancetype)initWithName:(NSString *)name
                          url:(NSURL *)url
                          type:(RNGSMBDirectoryItemType)type;
@end

NSErrorDomain const RNGSMBDirectoryBridgeErrorDomain =
    @"RNGSMBDirectoryBridgeErrorDomain";

namespace {

constexpr std::size_t kMaximumItems = 4096;
constexpr std::size_t kMaximumMRLBytes = 16 * 1024;
constexpr std::size_t kMaximumNameBytes = 4 * 1024;
constexpr std::size_t kMaximumCredentialBytes = 4 * 1024;
constexpr int kParseTimeoutMilliseconds = 15 * 1000;

void ClearTransient(std::string &value) noexcept {
    volatile char *bytes = value.empty() ? nullptr : value.data();
    for (std::size_t index = 0; index < value.size(); index += 1) {
        bytes[index] = 0;
    }
    value.clear();
    value.shrink_to_fit();
}

struct RequestState {
    std::atomic_bool cancelled{false};
    std::atomic_bool timedOut{false};
    std::atomic_bool finished{false};
    std::atomic_bool loginPrompted{false};
    std::atomic_bool authenticationFailed{false};

    std::mutex mediaMutex;
    libvlc_media_t *media = nullptr;

    std::atomic_bool parsing{false};
    std::atomic_bool stopRequested{false};
    std::atomic_bool stopScheduled{false};

    std::mutex stopMutex;
    std::condition_variable stopCondition;
    bool stopPending = false;

    std::mutex parseMutex;
    std::condition_variable parseCondition;
    bool parseTerminal = false;
    int parseStatus = 0;

    // These are transient operation inputs. clearCredentials() is called as
    // soon as the dialog callbacks are unregistered and before completion.
    std::mutex credentialMutex;
    std::string username;
    std::string password;

    void setMedia(libvlc_media_t *value) {
        std::lock_guard<std::mutex> lock(mediaMutex);
        media = value;
    }

    libvlc_media_t *retainedMediaForStop() {
        std::lock_guard<std::mutex> lock(mediaMutex);
        if (media == nullptr || !parsing.load(std::memory_order_acquire)) {
            return nullptr;
        }
        // The worker may release its ownership immediately after this lock is
        // dropped. Retain through the public API before calling parse_stop on
        // the caller's cancellation/watchdog thread.
        libvlc_media_retain(media);
        return media;
    }

    libvlc_media_t *takeMedia() {
        std::lock_guard<std::mutex> lock(mediaMutex);
        libvlc_media_t *value = media;
        media = nullptr;
        return value;
    }

    void signalParse(int status, bool terminal) {
        {
            std::lock_guard<std::mutex> lock(parseMutex);
            parseStatus = status;
            if (terminal) {
                parseTerminal = true;
            }
        }
        parseCondition.notify_all();
    }

    void clearCredentials() {
        std::lock_guard<std::mutex> lock(credentialMutex);
        ClearTransient(username);
        ClearTransient(password);
    }

    void waitForStop() {
        std::unique_lock<std::mutex> lock(stopMutex);
        stopCondition.wait(lock, [this] {
            return !stopRequested.load(std::memory_order_acquire) ||
                   (stopScheduled.load(std::memory_order_acquire) && !stopPending);
        });
    }

    void finishStop() {
        {
            std::lock_guard<std::mutex> lock(stopMutex);
            stopPending = false;
        }
        stopCondition.notify_all();
    }

    bool copyCredentials(std::string &outUsername, std::string &outPassword) {
        std::lock_guard<std::mutex> lock(credentialMutex);
        outUsername = username;
        outPassword = password;
        return !outUsername.empty();
    }
};

NSError *BridgeError(RNGSMBDirectoryBridgeErrorCode code) {
    NSString *description = @"SMBフォルダーの操作に失敗しました。";
    switch (code) {
        case RNGSMBDirectoryBridgeErrorInvalidURL:
            description = @"SMBアドレスが不正です。";
            break;
        case RNGSMBDirectoryBridgeErrorUnsupportedDomain:
            description = @"SMBドメイン認証には対応していません。";
            break;
        case RNGSMBDirectoryBridgeErrorUnavailable:
            description = @"SMB共有に接続できませんでした。";
            break;
        case RNGSMBDirectoryBridgeErrorAuthentication:
            description = @"SMB認証に失敗しました。";
            break;
        case RNGSMBDirectoryBridgeErrorTimeout:
            description = @"SMBフォルダーの読み込みがタイムアウトしました。";
            break;
        case RNGSMBDirectoryBridgeErrorCancelled:
            description = @"SMBフォルダーの読み込みをキャンセルしました。";
            break;
        case RNGSMBDirectoryBridgeErrorItemLimit:
            description = @"SMBフォルダーの項目数が上限を超えています。";
            break;
        case RNGSMBDirectoryBridgeErrorFailed:
            description = @"SMBフォルダーを読み込めませんでした。";
            break;
    }
    return [NSError errorWithDomain:RNGSMBDirectoryBridgeErrorDomain
                                code:code
                            userInfo:@{NSLocalizedDescriptionKey : description}];
}

bool CopyUTF8String(NSString *value, std::string &destination) {
    if (value == nil) {
        destination.clear();
        return true;
    }

    NSData *data = [value dataUsingEncoding:NSUTF8StringEncoding
                        allowLossyConversion:NO];
    if (data == nil || data.length > kMaximumCredentialBytes) {
        return false;
    }
    if (data.length > 0 && std::memchr(data.bytes, '\0', data.length) != nullptr) {
        return false;
    }

    if (data.length == 0) {
        destination.clear();
    } else {
        destination.assign(static_cast<const char *>(data.bytes), data.length);
    }
    return true;
}

NSURL *ValidatedSMBURL(NSURL *url) {
    if (url == nil) {
        return nil;
    }

    NSURLComponents *components =
        [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    NSString *scheme = components.scheme.lowercaseString;
    if (components == nil || ![scheme isEqualToString:@"smb"] ||
        components.host.length == 0 || components.user != nil ||
        components.password != nil || components.percentEncodedUser != nil ||
        components.percentEncodedPassword != nil || components.query != nil ||
        components.fragment != nil) {
        return nil;
    }

    // A path segment containing dot traversal is rejected before it reaches
    // LibVLC. Same-share and allowed-root checks remain a Core responsibility.
    for (NSString *component in components.path.pathComponents) {
        if ([component isEqualToString:@"."] ||
            [component isEqualToString:@".."] ) {
            return nil;
        }
    }

    NSString *absolute = components.string;
    if (absolute.length == 0 ||
        [absolute dataUsingEncoding:NSUTF8StringEncoding].length > kMaximumMRLBytes) {
        return nil;
    }
    return [NSURL URLWithString:absolute];
}

NSURL *ValidatedItemURL(const char *mrl) {
    if (mrl == nullptr) {
        return nil;
    }
    std::size_t length = strnlen(mrl, kMaximumMRLBytes + 1);
    if (length == 0 || length > kMaximumMRLBytes) {
        return nil;
    }

    NSString *string = [[NSString alloc] initWithBytes:mrl
                                                 length:length
                                               encoding:NSUTF8StringEncoding];
    if (string == nil) {
        return nil;
    }
    return ValidatedSMBURL([NSURL URLWithString:string]);
}

NSString *NameForItemURL(NSURL *url) {
    NSString *path = url.path;
    NSArray<NSString *> *components = path.pathComponents;
    for (NSInteger index = components.count - 1; index >= 0; index -= 1) {
        NSString *component = components[(NSUInteger)index];
        if ([component isEqualToString:@"/"] || component.length == 0) {
            continue;
        }
        NSData *bytes = [component dataUsingEncoding:NSUTF8StringEncoding];
        if (bytes.length == 0 || bytes.length > kMaximumNameBytes) {
            return nil;
        }
        return component;
    }
    return nil;
}

void SilentLog(void *, int, const libvlc_log_t *, const char *, va_list) {
    // Do not forward LibVLC messages. They may contain server paths,
    // usernames, or protocol diagnostics supplied by a remote peer.
}

libvlc_instance_t *CreateListingInstance() {
    // Keep all VLC-side credential lookup in this request's memory store.
    // The app's explicit Keychain item is the only persistent source.
    const char *options[] = {"--quiet", "--verbose=-1", "--keystore=memory"};
    libvlc_instance_t *instance = libvlc_new(3, options);
    if (instance != nullptr) {
        libvlc_log_set(instance, &SilentLog, nullptr);
    }
    return instance;
}

void ReleaseListingInstance(libvlc_instance_t *instance) {
    if (instance == nullptr) {
        return;
    }
    libvlc_log_unset(instance);
    libvlc_release(instance);
}

#if DEBUG
void DebugSMBEvent(const char *event,
                   int parseStatus,
                   bool hasError,
                   bool loginAttempt) {
    // Keep diagnostics fixed and numeric. Never include a URL, server name,
    // username, password, or LibVLC-supplied text here.
    std::fprintf(stderr,
                 "RNGSMB_DEBUG event=%s parse_status=%d error=%d login_attempt=%d\n",
                 event,
                 parseStatus,
                 hasError ? 1 : 0,
                 loginAttempt ? 1 : 0);
}
#else
void DebugSMBEvent(const char *, int, bool, bool) {}
#endif

void DismissDialog(void *, libvlc_dialog_id *dialog) {
    if (dialog != nullptr) {
        (void)libvlc_dialog_dismiss(dialog);
    }
}

void DisplayError(void *, const char *, const char *) {
    // The public bridge reports a generic NSError instead of exposing remote
    // dialog text.
}

void DisplayQuestion(void *,
                    libvlc_dialog_id *dialog,
                    const char *,
                    const char *,
                    libvlc_dialog_question_type,
                    const char *,
                    const char *,
                    const char *) {
    DismissDialog(nullptr, dialog);
}

void DisplayLogin(void *data,
                  libvlc_dialog_id *dialog,
                  const char *,
                  const char *,
                  const char *,
                  bool) {
    auto *state = static_cast<RequestState *>(data);
    if (state == nullptr || dialog == nullptr) {
        DismissDialog(nullptr, dialog);
        return;
    }

    bool firstPrompt = !state->loginPrompted.exchange(
        true, std::memory_order_acq_rel);
    DebugSMBEvent("login", 0, !firstPrompt, true);
    if (!firstPrompt) {
        // LibVLC may ask again after a rejected credential. Do not resend the
        // same secret indefinitely; dismiss the dialog and terminate this
        // request as a generic authentication failure.
        state->authenticationFailed.store(true, std::memory_order_release);
        DismissDialog(nullptr, dialog);
        state->signalParse(libvlc_media_parsed_status_failed, true);
        return;
    }

    std::string username;
    std::string password;
    if (state->cancelled.load(std::memory_order_acquire) ||
        state->timedOut.load(std::memory_order_acquire) ||
        !state->copyCredentials(username, password)) {
        if (!state->cancelled.load(std::memory_order_acquire) &&
            !state->timedOut.load(std::memory_order_acquire)) {
            state->authenticationFailed.store(true, std::memory_order_release);
        }
        DismissDialog(nullptr, dialog);
        return;
    }

    // b_store is deliberately false. The bridge never allows LibVLC to
    // persist credentials in its access module or dialog provider.
    (void)libvlc_dialog_post_login(dialog,
                                   username.c_str(),
                                   password.c_str(),
                                   false);
    ClearTransient(username);
    ClearTransient(password);
}

void MediaParsedChanged(const libvlc_event_t *event, void *data) {
    auto *state = static_cast<RequestState *>(data);
    if (state == nullptr || event == nullptr ||
        event->type != libvlc_MediaParsedChanged) {
        return;
    }

    int status = event->u.media_parsed_changed.new_status;
    bool terminal = status == libvlc_media_parsed_status_skipped ||
                    status == libvlc_media_parsed_status_failed ||
                    status == libvlc_media_parsed_status_timeout ||
                    status == libvlc_media_parsed_status_done;
    state->signalParse(status, terminal);
}

void ScheduleStopOnUtilityQueue(const std::shared_ptr<RequestState> &state) {
    if (state == nullptr) {
        return;
    }

    // A cancellation may originate from the MainActor. libvlc_media_parse_stop
    // can wait for the access/demux thread, so never call it synchronously on
    // the caller's thread. The retained reference keeps the media alive until
    // the stop call and its matching release have completed, even if the
    // worker proceeds to detach/release its own reference.
    bool alreadyScheduled = false;
    {
        std::lock_guard<std::mutex> lock(state->stopMutex);
        alreadyScheduled =
            state->stopScheduled.exchange(true, std::memory_order_acq_rel);
        if (!alreadyScheduled) {
            state->stopPending = true;
        }
    }
    if (!alreadyScheduled) {
        libvlc_media_t *media = state->retainedMediaForStop();
        if (media != nullptr) {
            std::shared_ptr<RequestState> stopState = state;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                libvlc_media_parse_stop(media);
                libvlc_media_release(media);
                stopState->finishStop();
            });
        } else {
            state->finishStop();
        }
    }
}

void StopParsing(const std::shared_ptr<RequestState> &state, bool timeout) {
    if (state == nullptr) {
        return;
    }
    if (timeout) {
        state->timedOut.store(true, std::memory_order_release);
    }

    // Do not make the caller acquire stopMutex. In particular, cancellation
    // can arrive on the MainActor while the worker is registering the async
    // parse operation under that mutex.
    bool alreadyRequested =
        state->stopRequested.exchange(true, std::memory_order_acq_rel);
    if (!alreadyRequested) {
        std::shared_ptr<RequestState> stopState = state;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            ScheduleStopOnUtilityQueue(stopState);
        });
    }
    state->signalParse(libvlc_media_parsed_status_timeout, true);
}

void SetDialogCallbacks(libvlc_instance_t *instance,
                        RequestState *state) {
    if (instance == nullptr) {
        return;
    }

    if (state != nullptr) {
        libvlc_dialog_cbs callbacks{};
        callbacks.pf_display_error = &DisplayError;
        callbacks.pf_display_login = &DisplayLogin;
        callbacks.pf_display_question = &DisplayQuestion;
        callbacks.pf_cancel = &DismissDialog;
        libvlc_dialog_set_callbacks(instance, &callbacks, state);
    } else {
        // The public API explicitly accepts NULL to unregister callbacks.
        libvlc_dialog_set_callbacks(instance, nullptr, nullptr);
    }
}

NSError *ParseStatusError(const std::shared_ptr<RequestState> &state,
                          int status) {
    if (state->cancelled.load(std::memory_order_acquire)) {
        return BridgeError(RNGSMBDirectoryBridgeErrorCancelled);
    }
    if (state->timedOut.load(std::memory_order_acquire) ||
        status == libvlc_media_parsed_status_timeout) {
        return BridgeError(RNGSMBDirectoryBridgeErrorTimeout);
    }
    if (state->authenticationFailed.load(std::memory_order_acquire) ||
        state->loginPrompted.load(std::memory_order_acquire)) {
        return BridgeError(RNGSMBDirectoryBridgeErrorAuthentication);
    }
    return BridgeError(RNGSMBDirectoryBridgeErrorUnavailable);
}

RNGSMBDirectoryItemType ItemTypeForMedia(libvlc_media_type_t type) {
    switch (type) {
        case libvlc_media_type_directory:
            return RNGSMBDirectoryItemTypeDirectory;
        case libvlc_media_type_file:
            return RNGSMBDirectoryItemTypeFile;
        default:
            return RNGSMBDirectoryItemTypeUnknown;
    }
}

NSArray<RNGSMBDirectoryItem *> *ReadSubitems(
    libvlc_media_t *media,
    const std::shared_ptr<RequestState> &state,
    NSError **error) {
    libvlc_media_list_t *list = libvlc_media_subitems(media);
    if (list == nullptr) {
        if (error != nullptr) {
            *error = BridgeError(RNGSMBDirectoryBridgeErrorFailed);
        }
        return nil;
    }

    NSArray<RNGSMBDirectoryItem *> *result = nil;
    libvlc_media_list_lock(list);
    do {
        int count = libvlc_media_list_count(list);
        if (count < 0 || static_cast<std::size_t>(count) > kMaximumItems) {
            if (error != nullptr) {
                *error = BridgeError(RNGSMBDirectoryBridgeErrorItemLimit);
            }
            break;
        }

        NSMutableArray<RNGSMBDirectoryItem *> *items =
            [NSMutableArray arrayWithCapacity:(NSUInteger)count];
        for (int index = 0; index < count; index += 1) {
            if (state->cancelled.load(std::memory_order_acquire) ||
                state->timedOut.load(std::memory_order_acquire)) {
                if (error != nullptr) {
                    *error = state->cancelled.load(std::memory_order_acquire)
                                 ? BridgeError(RNGSMBDirectoryBridgeErrorCancelled)
                                 : BridgeError(RNGSMBDirectoryBridgeErrorTimeout);
                }
                break;
            }

            libvlc_media_t *item = libvlc_media_list_item_at_index(list, index);
            if (item == nullptr) {
                continue;
            }

            char *mrl = libvlc_media_get_mrl(item);
            NSURL *itemURL = ValidatedItemURL(mrl);
            if (mrl != nullptr) {
                libvlc_free(mrl);
            }
            RNGSMBDirectoryItemType type =
                ItemTypeForMedia(libvlc_media_get_type(item));
            libvlc_media_release(item);

            NSString *name = NameForItemURL(itemURL);
            if (itemURL == nil || name == nil) {
                continue;
            }
            [items addObject:[[RNGSMBDirectoryItem alloc] initWithName:name
                                                                     url:itemURL
                                                                     type:type]];
        }
        if (error == nullptr || *error == nil) {
            result = [items copy];
        }
    } while (false);
    libvlc_media_list_unlock(list);
    libvlc_media_list_release(list);
    return result;
}

NSError *RunListing(libvlc_instance_t *instance,
                    const std::shared_ptr<RequestState> &state,
                    NSString *urlString,
                    NSArray<RNGSMBDirectoryItem *> **items) {
    if (items != nullptr) {
        *items = nil;
    }
    if (instance == nullptr || state == nullptr || urlString == nil) {
        return BridgeError(RNGSMBDirectoryBridgeErrorUnavailable);
    }
    if (state->cancelled.load(std::memory_order_acquire)) {
        return BridgeError(RNGSMBDirectoryBridgeErrorCancelled);
    }
    if (state->timedOut.load(std::memory_order_acquire)) {
        return BridgeError(RNGSMBDirectoryBridgeErrorTimeout);
    }

    NSData *urlData = [urlString dataUsingEncoding:NSUTF8StringEncoding];
    if (urlData == nil || urlData.length > kMaximumMRLBytes) {
        return BridgeError(RNGSMBDirectoryBridgeErrorInvalidURL);
    }
    std::string mrl(static_cast<const char *>(urlData.bytes), urlData.length);

    libvlc_media_t *media = libvlc_media_new_location(instance, mrl.c_str());
    if (media == nullptr) {
        return BridgeError(RNGSMBDirectoryBridgeErrorUnavailable);
    }
    state->setMedia(media);

    // Pass credentials through LibVLC's documented per-media options before
    // parsing. The option strings are copied by LibVLC, so clear every local
    // copy immediately after the calls. The dialog callback remains disabled
    // for storage and is only a bounded fallback for an authentication prompt.
    std::string username;
    std::string password;
    if (state->copyCredentials(username, password)) {
        std::string usernameOption = ":smb-user=" + username;
        std::string passwordOption = ":smb-pwd=" + password;
        libvlc_media_add_option(media, usernameOption.c_str());
        libvlc_media_add_option(media, passwordOption.c_str());
        ClearTransient(usernameOption);
        ClearTransient(passwordOption);
    }
    ClearTransient(username);
    ClearTransient(password);

    libvlc_event_manager_t *eventManager = libvlc_media_event_manager(media);
    bool attached = eventManager != nullptr &&
                    libvlc_event_attach(eventManager,
                                        libvlc_MediaParsedChanged,
                                        &MediaParsedChanged,
                                        state.get()) == 0;

    SetDialogCallbacks(instance, state.get());
    int parseResult = -1;
    {
        // Keep the start decision, parsing flag, and async parse registration
        // in the same boundary as StopParsing's stopScheduled decision. A
        // cancellation that wins this boundary prevents parse from starting;
        // one that arrives after it is guaranteed to schedule parse_stop.
        std::lock_guard<std::mutex> lock(state->stopMutex);
        bool canStart = attached &&
                        !state->cancelled.load(std::memory_order_acquire) &&
                        !state->timedOut.load(std::memory_order_acquire) &&
                        !state->stopRequested.load(std::memory_order_acquire) &&
                        !state->stopScheduled.load(std::memory_order_acquire);
        if (canStart) {
            state->parsing.store(true, std::memory_order_release);
            parseResult = libvlc_media_parse_with_options(
                media,
                static_cast<libvlc_media_parse_flag_t>(libvlc_media_parse_network |
                                                       libvlc_media_do_interact),
                kParseTimeoutMilliseconds);
        }
    }

    NSError *error = nil;
    int status = libvlc_media_parsed_status_failed;
    if (!attached) {
        error = BridgeError(RNGSMBDirectoryBridgeErrorUnavailable);
    } else if (parseResult < 0) {
        status = libvlc_media_get_parsed_status(media);
        error = ParseStatusError(state, status);
    } else {
        // A media descriptor that was already preparsed may not emit a new
        // MediaParsedChanged event. Read the public status before waiting so
        // that a valid cached parse is not turned into a false timeout.
        status = libvlc_media_get_parsed_status(media);
        // A fresh descriptor commonly reports "skipped" before preparsing
        // has started. Only the terminal done value is safe to use as a
        // cached-parse fast path; failure/timeout/skipped are taken from the
        // post-parse event or the bounded wait below.
        if (status == libvlc_media_parsed_status_done) {
            state->signalParse(status, true);
        }
        std::unique_lock<std::mutex> lock(state->parseMutex);
        if (!state->parseTerminal && !state->cancelled.load() &&
            !state->timedOut.load()) {
            const auto deadline = std::chrono::steady_clock::now() +
                                  std::chrono::milliseconds(kParseTimeoutMilliseconds);
            state->parseCondition.wait_until(lock, deadline, [&] {
                return state->parseTerminal ||
                       state->cancelled.load(std::memory_order_acquire) ||
                       state->timedOut.load(std::memory_order_acquire);
            });
        }
        status = state->parseStatus;
        if (!state->parseTerminal && !state->cancelled.load() &&
            !state->timedOut.load()) {
            lock.unlock();
            StopParsing(state, true);
            lock.lock();
            status = libvlc_media_parsed_status_timeout;
        }
        if (state->cancelled.load() || state->timedOut.load() ||
            state->authenticationFailed.load(std::memory_order_acquire) ||
            status != libvlc_media_parsed_status_done) {
            error = ParseStatusError(state, status);
        }
    }

    // Keep parsing=true until every path that can request parse_stop has
    // finished observing the asynchronous parse. This is deliberately before
    // media detachment/takeMedia, so a cancellation during the bounded wait
    // can still retain the media safely for its off-main stop call.
    state->parsing.store(false, std::memory_order_release);

    if (attached) {
        libvlc_event_detach(eventManager,
                            libvlc_MediaParsedChanged,
                            &MediaParsedChanged,
                            state.get());
    }
    SetDialogCallbacks(instance, nullptr);

    libvlc_media_t *ownedMedia = state->takeMedia();
    if (ownedMedia != nullptr) {
        if (error == nil &&
            (state->cancelled.load() || state->timedOut.load())) {
            error = state->cancelled.load()
                        ? BridgeError(RNGSMBDirectoryBridgeErrorCancelled)
                        : BridgeError(RNGSMBDirectoryBridgeErrorTimeout);
        }
        if (error == nil) {
            NSError *listError = nil;
            NSArray<RNGSMBDirectoryItem *> *listed =
                ReadSubitems(ownedMedia, state, &listError);
            if (listed == nil && listError != nil) {
                error = listError;
            } else if (items != nullptr) {
                *items = listed ?: @[];
            }
        }
        libvlc_media_release(ownedMedia);
    }

    state->clearCredentials();
    DebugSMBEvent("completion",
                  status,
                  error != nil,
                  state->loginPrompted.load(std::memory_order_acquire));
    if (error != nil) {
        return error;
    }
    if (items == nullptr || *items == nil) {
        return BridgeError(RNGSMBDirectoryBridgeErrorFailed);
    }
    return nil;
}

} // namespace

@implementation RNGSMBDirectoryItem {
    NSString *_name;
    NSURL *_url;
    RNGSMBDirectoryItemType _type;
}

- (instancetype)initWithName:(NSString *)name
                          url:(NSURL *)url
                          type:(RNGSMBDirectoryItemType)type {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _name = [name copy];
    _url = [url copy];
    _type = type;
    return self;
}

- (NSString *)name { return _name; }
- (NSURL *)itemURL { return _url; }
- (NSURL *)url { return _url; }
- (RNGSMBDirectoryItemType)type { return _type; }
- (BOOL)isDirectory { return _type == RNGSMBDirectoryItemTypeDirectory; }

@end

@interface RNGSMBDirectoryRequest ()
- (instancetype)initWithState:(std::shared_ptr<RequestState>)state;
@end

@implementation RNGSMBDirectoryRequest {
    std::shared_ptr<RequestState> _state;
}

- (instancetype)initWithState:(std::shared_ptr<RequestState>)state {
    self = [super init];
    if (self != nil) {
        _state = std::move(state);
    }
    return self;
}

- (BOOL)isCancelled {
    return _state != nullptr &&
           _state->cancelled.load(std::memory_order_acquire);
}

- (void)cancel {
    if (_state == nullptr || _state->finished.load(std::memory_order_acquire)) {
        return;
    }
    _state->cancelled.store(true, std::memory_order_release);
    StopParsing(_state, false);
}

@end

@interface RNGSMBDirectoryBridge ()
@end

@implementation RNGSMBDirectoryBridge {
    dispatch_queue_t _queue;
    dispatch_queue_t _cleanupQueue;
    NSLock *_requestLock;
    NSMutableSet<RNGSMBDirectoryRequest *> *_requests;
}

- (instancetype)init {
    self = [super init];
    if (self == nil) {
        return nil;
    }
    _queue = dispatch_queue_create("tv.ringonomi.smb-directory", DISPATCH_QUEUE_SERIAL);
    _cleanupQueue = dispatch_queue_create(
        "tv.ringonomi.smb-directory.cleanup", DISPATCH_QUEUE_SERIAL);
    _requestLock = [[NSLock alloc] init];
    _requests = [NSMutableSet set];
    return self;
}

- (void)removeRequest:(RNGSMBDirectoryRequest *)request {
    [_requestLock lock];
    [_requests removeObject:request];
    [_requestLock unlock];
}

- (RNGSMBDirectoryRequest *)listDirectoryAtURL:(NSURL *)url
                                       username:(NSString *)username
                                       password:(NSString *)password
                                         domain:(NSString *)domain
                                     completion:(RNGSMBDirectoryCompletion)completion {
    std::shared_ptr<RequestState> state = std::make_shared<RequestState>();
    RNGSMBDirectoryRequest *request =
        [[RNGSMBDirectoryRequest alloc] initWithState:state];
    [_requestLock lock];
    [_requests addObject:request];
    [_requestLock unlock];

    NSURL *validatedURL = ValidatedSMBURL(url);
    NSError *validationError = nil;
    if (validatedURL == nil) {
        validationError = BridgeError(RNGSMBDirectoryBridgeErrorInvalidURL);
    } else if (domain.length > 0) {
        // libvlc_dialog_post_login has no domain argument. Do not guess a
        // private SMB option or silently fold domain into the username.
        validationError = BridgeError(RNGSMBDirectoryBridgeErrorUnsupportedDomain);
    } else if (!CopyUTF8String(username, state->username) ||
               !CopyUTF8String(password, state->password)) {
        validationError = BridgeError(RNGSMBDirectoryBridgeErrorInvalidURL);
    } else if (state->username.empty()) {
        // Guest access must not retain a password that can never be posted.
        ClearTransient(state->password);
    }

    __weak RNGSMBDirectoryBridge *weakSelf = self;
    if (validationError != nil) {
        state->clearCredentials();
        state->finished.store(true, std::memory_order_release);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion != nil) {
                completion(nil, validationError);
            }
            [weakSelf removeRequest:request];
        });
        return request;
    }

    NSString *urlString = validatedURL.absoluteString;
    dispatch_queue_t cleanupQueue = _cleanupQueue;
    // Start the deadline when the request is accepted, including time spent
    // waiting behind an earlier operation on the serial worker queue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)kParseTimeoutMilliseconds * NSEC_PER_MSEC),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!state->finished.load(std::memory_order_acquire)) {
            StopParsing(state, true);
        }
    });
    dispatch_async(_queue, ^{
        @autoreleasepool {
            NSArray<RNGSMBDirectoryItem *> *items = nil;
            NSError *error = nil;
            libvlc_instance_t *instance = nullptr;
            if (state->cancelled.load(std::memory_order_acquire)) {
                error = BridgeError(RNGSMBDirectoryBridgeErrorCancelled);
            } else if (state->timedOut.load(std::memory_order_acquire)) {
                error = BridgeError(RNGSMBDirectoryBridgeErrorTimeout);
            } else {
                instance = CreateListingInstance();
                if (instance == nullptr) {
                    error = BridgeError(RNGSMBDirectoryBridgeErrorUnavailable);
                } else {
                    error = RunListing(instance, state, urlString, &items);
                    // Cleanup is deliberately enqueued after completion is
                    // prepared below. The UI and request worker never wait
                    // for a potentially slow LibVLC release.
                }
            }
            // Also covers a cancellation or timeout observed before the
            // worker creates a media descriptor, where RunListing returns
            // before reaching its normal cleanup path.
            state->clearCredentials();
            state->finished.store(true, std::memory_order_release);

            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion != nil) {
                    completion(items, error);
                }
                [weakSelf removeRequest:request];
            });

            if (instance != nullptr) {
                dispatch_async(cleanupQueue, ^{
                    state->waitForStop();
                    ReleaseListingInstance(instance);
                });
            }
        }
    });
    return request;
}

- (void)cancelAllRequests {
    NSArray<RNGSMBDirectoryRequest *> *requests = nil;
    [_requestLock lock];
    requests = [_requests allObjects];
    [_requestLock unlock];
    for (RNGSMBDirectoryRequest *request in requests) {
        [request cancel];
    }
}

- (void)dealloc {
    [self cancelAllRequests];
}

@end
