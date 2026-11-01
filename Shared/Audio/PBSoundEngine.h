//
//  PBSoundEngine.h
//  All sound is synthesized at launch into PCM buffers. No audio files, so no app size.
//

#import <Foundation/Foundation.h>
#import "PBGame.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBSoundEngine : NSObject <PBGameObserver>
- (instancetype)init;
- (void)start;
@end

NS_ASSUME_NONNULL_END
