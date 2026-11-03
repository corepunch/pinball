//
//  PBLevels.m
//

#import "PBLevels.h"

static NSString *const kProgressKey = @"PBLevelProgress";

static NSDictionary<NSString *, NSString *> *PBGoalNames(void) {
    return @{ @"ramps": @"RAMP", @"bumpers": @"BUMPER", @"drops": @"DROP TARGET", @"saucers": @"SCOOP SHOT",
              @"spinners": @"SPINNER SPIN", @"multiballs": @"MULTIBALL", @"jackpots": @"JACKPOT", @"standups": @"TARGET", @"wizards": @"WIZARD MODE" };
}

static NSString *PBFormatted(int64_t value) {
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US"];
    formatter.numberStyle = NSNumberFormatterDecimalStyle;
    return [formatter stringFromNumber:@(value)];
}

static NSError *PBLevelError(NSString *message) {
    return [NSError errorWithDomain:@"PBLevels" code:1 userInfo:@{ NSLocalizedDescriptionKey: message }];
}

@interface PBLevelDef ()
@property (nonatomic, copy) NSString *identifier, *name, *table, *skin, *goal;
@property (nonatomic, copy, nullable) NSString *introduces;
@property (nonatomic) int64_t goalCount, twoStarScore, threeStarScore;
@end

@implementation PBLevelDef

- (NSString *)goalText {
    if ([self.goal isEqualToString:@"score"]) return [@"SCORE " stringByAppendingString:PBFormatted(self.goalCount)];
    NSString *name = PBGoalNames()[self.goal];
    return self.goalCount == 1 ? [@"1 " stringByAppendingString:name]
                               : [NSString stringWithFormat:@"%lld %@S", (long long)self.goalCount, name];
}

- (NSInteger)starsForScore:(int64_t)score goalMet:(BOOL)goalMet {
    if (!goalMet) return 0;
    return score >= self.threeStarScore ? 3 : score >= self.twoStarScore ? 2 : 1;
}

@end

@implementation PBLevelCatalog

- (instancetype)initWithJSONData:(NSData *)data error:(NSError **)error {
    if ((self = [super init])) {
        NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:error];
        if (![json isKindOfClass:NSDictionary.class]) return nil;
        NSMutableArray *levels = [NSMutableArray array];
        NSMutableSet *seen = [NSMutableSet set];
        NSSet *counted = [NSSet setWithArray:PBGoalNames().allKeys];
        for (NSDictionary *item in json[@"levels"]) {
            PBLevelDef *level = [PBLevelDef new];
            level.identifier = item[@"id"];
            level.name = item[@"name"];
            level.table = item[@"table"];
            level.skin = item[@"skin"];
            level.goal = item[@"goal"];
            level.introduces = [item[@"introduces"] isKindOfClass:NSString.class] ? item[@"introduces"] : nil;
            level.goalCount = [item[@"count"] longLongValue];
            NSArray *stars = item[@"stars"];
            BOOL valid = level.identifier.length && level.name.length && level.table.length && level.skin.length && level.goalCount > 0
                && ([level.goal isEqualToString:@"score"] || [counted containsObject:level.goal]) && stars.count == 2 && ![seen containsObject:level.identifier];
            if (valid) {
                level.twoStarScore = [stars[0] longLongValue];
                level.threeStarScore = [stars[1] longLongValue];
                int64_t floor = [level.goal isEqualToString:@"score"] ? level.goalCount : 0;
                valid = level.twoStarScore > floor && level.threeStarScore > level.twoStarScore;
            }
            if (!valid) {
                if (error) *error = PBLevelError([NSString stringWithFormat:@"Invalid level: %@", item]);
                return nil;
            }
            [seen addObject:level.identifier];
            [levels addObject:level];
        }
        if (!levels.count) {
            if (error) *error = PBLevelError(@"No levels");
            return nil;
        }
        _levels = levels;
    }
    return self;
}

+ (instancetype)catalogInBundle:(NSBundle *)bundle error:(NSError **)error {
    NSURL *url = [bundle URLForResource:@"Levels" withExtension:@"json" subdirectory:@"GameData"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url options:0 error:error] : nil;
    return data ? [[self alloc] initWithJSONData:data error:error] : nil;
}

@end

@implementation PBLevelProgress {
    NSUserDefaults *_defaults;
    NSMutableDictionary<NSString *, NSDictionary *> *_entries;
}

- (instancetype)initWithDefaults:(NSUserDefaults *)defaults {
    if ((self = [super init])) {
        _defaults = defaults;
        NSDictionary *saved = [defaults dictionaryForKey:kProgressKey];
        _entries = saved ? [saved mutableCopy] : [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSInteger)totalStars {
    NSInteger total = 0;
    for (NSDictionary *entry in _entries.allValues) total += [entry[@"stars"] integerValue];
    return total;
}

- (NSInteger)starsForLevel:(PBLevelDef *)level { return [_entries[level.identifier][@"stars"] integerValue]; }
- (int64_t)bestScoreForLevel:(PBLevelDef *)level { return [_entries[level.identifier][@"best"] longLongValue]; }

- (void)recordStars:(NSInteger)stars score:(int64_t)score forLevel:(PBLevelDef *)level {
    _entries[level.identifier] = @{ @"stars": @(MAX(stars, [self starsForLevel:level])),
                                    @"best": @(MAX(score, [self bestScoreForLevel:level])) };
    [_defaults setObject:_entries forKey:kProgressKey];
}

- (BOOL)isLevelUnlockedAtIndex:(NSInteger)index inCatalog:(PBLevelCatalog *)catalog {
    if (index <= 0) return YES;
    if (index >= (NSInteger)catalog.levels.count) return NO;
    return [self starsForLevel:catalog.levels[(NSUInteger)index - 1]] > 0;
}

- (NSInteger)currentLevelIndexInCatalog:(PBLevelCatalog *)catalog {
    NSInteger count = (NSInteger)catalog.levels.count;
    for (NSInteger i = 0; i < count; i++) {
        if ([self starsForLevel:catalog.levels[(NSUInteger)i]] == 0) return i;
    }
    return count - 1;
}

@end

@implementation PBLevelSession {
    BOOL _announcedGoal;
}

- (instancetype)initWithLevel:(PBLevelDef *)level {
    if ((self = [super init])) _level = level;
    return self;
}

- (BOOL)goalMet { return _progress >= _level.goalCount; }

/// Counted goals with a long way to go only report at each quarter, to leave the HUD to the game.
- (void)countInGame:(PBGame *)game {
    _progress++;
    int64_t count = _level.goalCount;
    if (self.goalMet) {
        [self announceGoalInGame:game];
    } else if (count <= 12 || _progress % MAX(count / 4, 1) == 0) {
        [game.rules showMessage:[NSString stringWithFormat:@"%lld OF %lld", (long long)_progress, (long long)count]];
    }
}

- (void)announceGoalInGame:(PBGame *)game {
    if (_announcedGoal) return;
    _announcedGoal = YES;
    [game.rules showMessage:@"GOAL COMPLETE"];
}

- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    NSString *goal = _level.goal;
    if ([goal isEqualToString:@"score"]) {
        _progress = game.rules.score;
        if (self.goalMet) [self announceGoalInGame:game];
        return;
    }
    BOOL counts = (event->kind == PBEventRampComplete && [goal isEqualToString:@"ramps"])
        || (event->kind == PBEventBumper && [goal isEqualToString:@"bumpers"])
        || (event->kind == PBEventDropTarget && [goal isEqualToString:@"drops"])
        || (event->kind == PBEventSaucerCapture && [goal isEqualToString:@"saucers"])
        || (event->kind == PBEventSpinner && [goal isEqualToString:@"spinners"])
        || (event->kind == PBEventStandup && [goal isEqualToString:@"standups"]);
    if (counts) [self countInGame:game];
}

- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {}

- (void)game:(PBGame *)game fanfare:(NSString *)name {
    if ([name isEqualToString:@"start"]) {
        _progress = 0;
        _announcedGoal = NO;
        [game.rules showMessage:_level.goalText];
    } else if ([name isEqualToString:@"gameOver"] && [_level.goal isEqualToString:@"score"]) {
        // End-of-ball bonuses count, and arrive with no event of their own.
        _progress = game.rules.score;
    } else if (([name isEqualToString:@"multiball"] && [_level.goal isEqualToString:@"multiballs"])
               || ([name isEqualToString:@"jackpot"] && [_level.goal isEqualToString:@"jackpots"])
               || ([name isEqualToString:@"wizard"] && [_level.goal isEqualToString:@"wizards"])) {
        [self countInGame:game];
    }
}

@end
