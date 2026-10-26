#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`, returning the Objective-C exception it raised (if any) instead of
/// letting it abort the app. Swift can't catch these; AVFAudio raises them for
/// misuse it could have reported as errors.
NSException *_Nullable STMCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
