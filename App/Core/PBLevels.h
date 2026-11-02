//
//  PBLevels.h
//  Levels are data: GameData/Levels.json pairs a table and skin with a goal and star scores.
//  A level's goal earns its first star and unlocks the next level; its score earns the others.
//  No SceneKit, UIKit or AppKit here, so all of it runs in the unit tests.
//

#import <Foundation/Foundation.h>
#import "PBGame.h"

NS_ASSUME_NONNULL_BEGIN

@interface PBLevelDef : NSObject
@property (nonatomic, copy, readonly) NSString *identifier;
@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *table;
@property (nonatomic, copy, readonly) NSString *skin;
/// "score", or what to count: "ramps", "bumpers", "drops", "saucers", "spinners", "multiballs", "jackpots", "standups" or "wizards".
@property (nonatomic, copy, readonly) NSString *goal;
@property (nonatomic, readonly) int64_t goalCount;
@property (nonatomic, readonly) int64_t twoStarScore;
@property (nonatomic, readonly) int64_t threeStarScore;
/// For a player: "SCORE 50,000" or "3 RAMPS".
@property (nonatomic, copy, readonly) NSString *goalText;
- (NSInteger)starsForScore:(int64_t)score goalMet:(BOOL)goalMet;
@end

@interface PBLevelCatalog : NSObject
@property (nonatomic, copy, readonly) NSArray<PBLevelDef *> *levels;
- (nullable instancetype)initWithJSONData:(NSData *)data error:(NSError **)error;
+ (nullable instancetype)catalogInBundle:(NSBundle *)bundle error:(NSError **)error;
@end

/// Stars and best scores, by level id, so reordering or adding levels keeps what was earned.
@interface PBLevelProgress : NSObject
@property (nonatomic, readonly) NSInteger totalStars;
- (instancetype)initWithDefaults:(NSUserDefaults *)defaults;
- (NSInteger)starsForLevel:(PBLevelDef *)level;
- (int64_t)bestScoreForLevel:(PBLevelDef *)level;
/// Only ever improves what is saved.
- (void)recordStars:(NSInteger)stars score:(int64_t)score forLevel:(PBLevelDef *)level;
/// The first level is always open; each other opens once the one before it has a star.
- (BOOL)isLevelUnlockedAtIndex:(NSInteger)index inCatalog:(PBLevelCatalog *)catalog;
/// The furthest open level without a star, or the last level when all have one.
- (NSInteger)currentLevelIndexInCatalog:(PBLevelCatalog *)catalog;
@end

/// Follows one level through a game, and reports on the HUD.
/// It is a game observer, so it runs on the render thread.
@interface PBLevelSession : NSObject <PBGameObserver>
@property (nonatomic, strong, readonly) PBLevelDef *level;
@property (nonatomic, readonly) int64_t progress;
@property (nonatomic, readonly) BOOL goalMet;
- (instancetype)initWithLevel:(PBLevelDef *)level;
@end

NS_ASSUME_NONNULL_END
