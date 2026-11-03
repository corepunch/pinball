// Plays one table headlessly with the autopilot, and reports what happened as one line of JSON.
// playtest <table.json> <games> [skip-validator]; see run_playtests.py.
#import <Foundation/Foundation.h>
#import "PBGame.h"
#import "PBLayoutValidator.h"

@interface PBPlaytest : NSObject <PBGameObserver>
@property (nonatomic, strong) NSMutableArray<NSMutableDictionary *> *games;
@property (nonatomic, strong) NSCountedSet<NSString *> *reached;
@property (nonatomic) NSInteger stuck, drains;
@property (nonatomic, strong) NSCountedSet<NSString *> *stuckAt;
@end

@implementation PBPlaytest {
    NSMutableDictionary<NSString *, NSNumber *> *_current;
}

- (instancetype)init {
    if ((self = [super init])) { _games = [NSMutableArray array]; _reached = [NSCountedSet set]; _stuckAt = [NSCountedSet set]; }
    return self;
}

- (void)count:(NSString *)key {
    if (_current) _current[key] = @(_current[key].integerValue + 1);
}

- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    PBTableDefinition *t = game.table;
    NSInteger e = event->element;
    switch (event->kind) {
        case PBEventBumper: [self count:@"bumpers"]; [_reached addObject:t.bumpers[e].identifier]; break;
        case PBEventDropTarget: [self count:@"drops"]; [_reached addObject:t.dropTargets[e].identifier]; break;
        case PBEventStandup: [self count:@"standups"]; [_reached addObject:t.standups[e].identifier]; break;
        case PBEventSpinner: [self count:@"spinners"]; [_reached addObject:t.spinners[e].identifier]; break;
        case PBEventSaucerCapture: [self count:@"saucers"]; [_reached addObject:t.saucers[e].identifier]; break;
        case PBEventRampComplete: [self count:@"ramps"]; [_reached addObject:t.ramps[e].identifier]; break;
        case PBEventRollover: [_reached addObject:t.rollovers[e].identifier]; break;
        case PBEventSling: [_reached addObject:t.slingshots[e].identifier]; break;
        case PBEventKickback: [_reached addObject:@"kickback"]; break;
        case PBEventMagnetGrab: [_reached addObject:@"magnet"]; break;
        case PBEventBallStuck:
            _stuck++;
            [_stuckAt addObject:[NSString stringWithFormat:@"%.2f,%.2f", round(event->position.x * 50) / 50, round(event->position.y * 50) / 50]];
            break;
        case PBEventDrain: _drains++; break;
        default: break;
    }
}

- (void)game:(PBGame *)game flash:(NSString *)flasherIdentifier {}

- (void)game:(PBGame *)game fanfare:(NSString *)name {
    if ([name isEqualToString:@"start"]) {
        _current = [NSMutableDictionary dictionary];
    } else if ([name isEqualToString:@"gameOver"] && _current) {
        _current[@"score"] = @(game.rules.score);
        [_games addObject:(NSMutableDictionary *)_current];
        _current = nil;
    } else if ([name isEqualToString:@"multiball"]) {
        [self count:@"multiballs"];
    } else if ([name isEqualToString:@"jackpot"]) {
        [self count:@"jackpots"];
    } else if ([name isEqualToString:@"wizard"]) {
        [self count:@"wizards"];
    }
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        NSError *error;
        PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSData dataWithContentsOfFile:@(argv[1])] error:&error];
        if (!table) { fprintf(stderr, "%s: %s\n", argv[1], error.localizedDescription.UTF8String); return 1; }
        int wanted = atoi(argv[2]);
        PBPlaytest *test = [PBPlaytest new];
        PBGame *game = [[PBGame alloc] initWithTable:table highScore:0];
        [game addObserver:test];
        game.autopilot = YES;
        long frames = 0, limit = 60L * 60 * 90;
        for (; frames < limit && (int)test.games.count < wanted; frames++) [game update:1.0 / 60.0];

        NSMutableArray *issues = [NSMutableArray array];
        for (PBLayoutIssue *issue in [PBLayoutValidator issuesForTable:table]) {
            [issues addObject:[NSString stringWithFormat:@"%@/%@ %.3f at %.2f,%.2f", issue.first, issue.second ?: @"-", issue.amount, issue.location.x, issue.location.y]];
        }
        NSMutableArray *never = [NSMutableArray array];
        NSMutableArray<PBElementDef *> *parts = [NSMutableArray array];
        for (NSArray *list in @[ table.bumpers, table.dropTargets, table.standups, table.spinners, table.saucers, table.ramps, table.rollovers, table.slingshots ]) [parts addObjectsFromArray:list];
        for (PBElementDef *part in parts) if (![test.reached countForObject:part.identifier]) [never addObject:part.identifier];
        NSMutableDictionary *stuckAt = [NSMutableDictionary dictionary];
        for (NSString *spot in test.stuckAt) stuckAt[spot] = @([test.stuckAt countForObject:spot]);
        NSDictionary *report = @{ @"stuckAt": stuckAt, @"table": table.identifier, @"games": test.games, @"minutes": @(frames / 3600.0), @"stuck": @(test.stuck), @"drains": @(test.drains),
                                  @"issues": issues, @"never": never };
        NSData *json = [NSJSONSerialization dataWithJSONObject:report options:0 error:NULL];
        fwrite(json.bytes, json.length, 1, stdout);
        printf("\n");
    }
    return 0;
}
