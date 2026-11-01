// Validate an exported Blender table with the actual game simulation and layout validator.
#import <Foundation/Foundation.h>
#import "PBGame.h"
#import "PBLevels.h"
#import "PBLayoutValidator.h"
#import <math.h>

@interface PBExportObserver : NSObject <PBGameObserver>
@property NSMutableSet<NSString *> *visited;
@property NSArray<PBLevelSession *> *sessions;
@end
@implementation PBExportObserver
- (instancetype)init { if ((self=[super init])) _visited=[NSMutableSet set]; return self; }
- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event {
    if (event->kind==PBEventRampComplete) [_visited addObject:game.table.ramps[event->element].identifier];
    if (event->kind==PBEventBumper) [_visited addObject:@"bumper"];
    if (event->kind==PBEventSling) [_visited addObject:@"sling"];
    if (event->kind==PBEventDropTarget) [_visited addObject:@"drop"];
    if (event->kind==PBEventSpinner) [_visited addObject:@"spinner"];
    if (event->kind==PBEventSaucerCapture) [_visited addObject:@"saucer"];
    if (event->kind==PBEventMagnetGrab) [_visited addObject:@"magnet"];
    if (event->kind==PBEventRollover) [_visited addObject:game.table.rollovers[event->element].identifier];
    if (event->kind==PBEventStandup) [_visited addObject:game.table.standups[event->element].identifier];
}
- (void)game:(PBGame *)game flash:(NSString *)identifier {}
- (void)game:(PBGame *)game fanfare:(NSString *)name {
    if ([name isEqualToString:@"gameOver"]) for (PBLevelSession *session in _sessions) {
        if (session.goalMet) [_visited addObject:[@"goal:" stringByAppendingString:session.level.identifier]];
    }
}
@end
int main(int argc,const char **argv) { @autoreleasepool {
    if (argc<2) return 2;
    NSError *error=nil;
    PBTableDefinition *table=[[PBTableDefinition alloc] initWithJSONData:[NSData dataWithContentsOfFile:@(argv[1])] error:&error];
    if (!table) { NSLog(@"Invalid table: %@",error);return 1; }
    PBLevelCatalog *catalog=argc>2 ? [[PBLevelCatalog alloc] initWithJSONData:[NSData dataWithContentsOfFile:@(argv[2])] error:&error] : nil;
    if (argc>2 && !catalog) { NSLog(@"Invalid campaign: %@",error);return 1; }
    NSArray *issues=[PBLayoutValidator issuesForTable:table];
    for (PBLayoutIssue *issue in issues) NSLog(@"Layout issue %ld: %@ / %@ at %.3f, %.3f (%.4f)",(long)issue.kind,issue.first,issue.second,issue.location.x,issue.location.y,issue.amount);
    if (issues.count) return 1;
    PBPhysicsWorld *launch=[[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger ball=[launch spawnBallAtPlunger];[launch setPlungerPulled:YES];
    for (int i=0;i<60;i++) [launch advanceBy:1.0/60.0];
    [launch setPlungerPulled:NO];float top=0,left=table.size.x;
    for (int i=0;i<180;i++) { [launch advanceBy:1.0/60.0];top=MAX(top,launch.balls[ball].position.y);left=MIN(left,launch.balls[ball].position.x); }
    if (top<table.size.y*.83f || left>table.size.x*.8f) { NSLog(@"Full-power launch does not reach the top lanes and clear the shooter gate");return 1; }
    PBGame *game=[[PBGame alloc] initWithTable:table highScore:0];
    NSMutableArray *sessions=[NSMutableArray array];
    for (PBLevelDef *level in catalog.levels) if ([level.table isEqualToString:table.identifier]) {
        PBLevelSession *session=[[PBLevelSession alloc] initWithLevel:level];[sessions addObject:session];[game addObserver:session];
    }
    PBExportObserver *observer=[PBExportObserver new];observer.sessions=sessions;[game addObserver:observer];game.autopilot=YES;
    int64_t score=0;
    for (int frame=0;frame<60*60*40;frame++) {
        [game update:1.0/60.0];score=MAX(score,game.rules.score);
        const PBBall *balls=game.world.balls;
        for (NSInteger i=0;i<game.world.ballCapacity;i++) {
            if (balls[i].state==PBBallInactive) continue;
            if (!isfinite(balls[i].position.x)||!isfinite(balls[i].position.y)||!isfinite(balls[i].z)||!isfinite(balls[i].velocity.x)||!isfinite(balls[i].velocity.y)) { NSLog(@"Physics became non-finite");return 1; }
        }
    }
    for (PBRampDef *ramp in table.ramps) if (![observer.visited containsObject:ramp.identifier]) { NSLog(@"Ramp %@ was never completed in the 40-minute autoplay validation",ramp.identifier);return 1; }
    NSMutableArray<NSString *> *required=[NSMutableArray array];
    if (table.bumpers.count) [required addObject:@"bumper"];
    if (table.slingshots.count) [required addObject:@"sling"];
    if (table.dropTargets.count) [required addObject:@"drop"];
    if (table.spinners.count) [required addObject:@"spinner"];
    if (table.saucers.count) [required addObject:@"saucer"];
    if (table.magnets.count) [required addObject:@"magnet"];
    for (PBSpotDef *item in table.rollovers) [required addObject:item.identifier];
    for (PBEdgeDef *item in table.standups) [required addObject:item.identifier];
    for (NSString *key in required) if (![observer.visited containsObject:key]) { NSLog(@"Gameplay feature %@ was never reached in autoplay validation",key);return 1; }
    for (PBLevelSession *session in sessions) if (![observer.visited containsObject:[@"goal:" stringByAppendingString:session.level.identifier]]) { NSLog(@"Campaign goal %@ was never achieved in a completed autoplay game",session.level.identifier);return 1; }
    if (score<15000 || (table.bumpers.count && ![observer.visited containsObject:@"bumper"])) { NSLog(@"Autoplay could not demonstrate scoring gameplay");return 1; }
    NSLog(@"VALID %@: no layout issues; 40 simulated minutes; all ramps completed; best score %lld",table.identifier,score);
    return 0;
} }
