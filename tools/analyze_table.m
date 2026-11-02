// Native, render-free production-physics runner. One JSON request per stdin line.
// Kept outside App so analysis, trace serialization and dispatch never enter the game.
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import "PBGame.h"
#import "PBLayoutValidator.h"
#import <math.h>
#include <stdio.h>
#include <stdlib.h>

@interface PBAnalysisObserver : NSObject <PBGameObserver>
@property (nonatomic, copy) void (^receive)(const PBEvent *);
@end
@implementation PBAnalysisObserver
- (void)game:(PBGame *)game didReceiveEvent:(const PBEvent *)event { self.receive(event); }
- (void)game:(PBGame *)game flash:(NSString *)identifier {}
- (void)game:(PBGame *)game fanfare:(NSString *)name {}
@end

static simd_float2 Vec(NSArray *v) { return simd_make_float2([v[0] floatValue], [v[1] floatValue]); }
static double Now(void) { return NSProcessInfo.processInfo.systemUptime; }
static NSArray *Inventory(PBTableDefinition *t) {
    NSMutableArray *result = [NSMutableArray array];
    NSDictionary *groups = @{ @"bumper":t.bumpers, @"sling":t.slingshots, @"drop":t.dropTargets,
        @"standup":t.standups, @"rollover":t.rollovers, @"spinner":t.spinners, @"saucer":t.saucers,
        @"kickback":t.kickbacks, @"magnet":t.magnets, @"rampComplete":t.ramps, @"gate":t.gates,
        @"flipperContact":t.flippers };
    for (NSString *kind in [groups.allKeys sortedArrayUsingSelector:@selector(compare:)])
        for (PBElementDef *item in groups[kind]) [result addObject:@{ @"event":kind, @"element":item.identifier }];
    return result;
}

static NSDictionary *Trial(PBTableDefinition *table, NSDictionary *spec, NSInteger width) {
    double started = Now();
    uint32_t seed = [spec[@"seed"] unsignedIntValue];
    BOOL autoplay = [spec[@"mode"] isEqualToString:@"autoplay"];
    PBGame *game = autoplay ? [[PBGame alloc] initWithTable:table highScore:0 seed:seed] : nil;
    PBPhysicsWorld *world = game ? game.world : [[PBPhysicsWorld alloc] initWithTable:table seed:seed];
    world.automaticBallSearch = [spec[@"rescue"] boolValue];
    NSInteger ball = -1;
    if (game) { game.autopilot = YES; [game requestNewGame]; }
    else {
        ball = [world spawnBallAtPlunger];
        [world placeBall:ball at:Vec(spec[@"position"]) velocity:Vec(spec[@"velocity"])];
    }
    for (NSUInteger i=0; i<table.magnets.count; i++) [world setMagnet:(NSInteger)i armed:[spec[@"magnets"] containsObject:table.magnets[i].identifier]];
    for (NSUInteger i=0; i<table.kickbacks.count; i++) [world setKickback:(NSInteger)i armed:[spec[@"kickbacks"] containsObject:table.kickbacks[i].identifier]];
    for (NSUInteger i=0; i<table.dropTargets.count; i++) if ([spec[@"dropsDown"] containsObject:table.dropTargets[i].identifier]) [world setDropTarget:(NSInteger)i up:NO];
    NSInteger height = (NSInteger)ceil(table.size.y / table.size.x * width);
    NSInteger count = width * height * 2;
    double *seconds = calloc((size_t)count, sizeof(double));
    double *vx = calloc((size_t)count, sizeof(double)), *vy = calloc((size_t)count, sizeof(double));
    uint8_t *visited = calloc((size_t)count, 1);
    NSMutableArray *events = [NSMutableArray array], *trace = [NSMutableArray array];
    __block BOOL invalid = NO, drained = NO, stuck = NO;
    __block NSInteger next = 0;
    __block int routeBall = -1;
    NSArray *expected = spec[@"expect"] ?: @[];
    void (^receive)(const PBEvent *) = ^(const PBEvent *e) {
        NSString *kind = PBEventName(e->kind), *identifier = PBEventElementIdentifier(*e, table);
        [events addObject:@{ @"event":kind, @"element":identifier, @"ball":@(e->ball), @"tick":@(e->tick),
            @"position":@[ @(e->position.x), @(e->position.y) ], @"magnitude":@(e->magnitude) }];
        if (e->kind == PBEventBallStuck) stuck = YES;
        if (e->kind == PBEventDrain && (autoplay || e->ball == ball)) {
            drained = YES;
            if (!isfinite(e->position.x) || !isfinite(e->position.y) || e->position.x<0 || e->position.x>table.size.x || e->position.y>table.size.y) invalid=YES;
        }
        if (next < (NSInteger)expected.count) {
            NSDictionary *goal = expected[next];
            if ([kind isEqual:goal[@"event"]] && (!goal[@"element"] || [identifier isEqual:goal[@"element"]]) &&
                e->ball >= 0 && (routeBall < 0 || routeBall == e->ball)) {
                routeBall = e->ball;
                next++;
            }
        }
    };
    PBAnalysisObserver *observer = [PBAnalysisObserver new]; observer.receive = receive;
    if (game) [game addObserver:observer];
    NSArray *controls = spec[@"controls"] ?: @[];
    NSInteger input = 0;
    uint64_t total = (uint64_t)llround([spec[@"seconds"] doubleValue] * 960.0);
    uint64_t steps = 0;
    BOOL returned = NO;
    for (uint64_t tick=0; tick<total;) {
        @autoreleasepool {
            // Controls are quantized to production 60 Hz input frames, not superhuman subframes.
            if (!game && tick % 16 == 0) {
                while (input < (NSInteger)controls.count && [controls[input][@"at"] doubleValue] <= (double)tick/960.0 + 1e-9) {
                    NSDictionary *c = controls[input++];
                    if (c[@"left"]) [world setFlipperGroupLeft:YES pressed:[c[@"left"] boolValue]];
                    if (c[@"right"]) [world setFlipperGroupLeft:NO pressed:[c[@"right"] boolValue]];
                    if (c[@"eject"]) for (NSUInteger i=0;i<table.saucers.count;i++) if ([table.saucers[i].identifier isEqual:c[@"eject"]]) [world ejectSaucer:(NSInteger)i];
                }
            }
            uint64_t stride = game ? 16 : 1;
            if (game) [game update:1.0/60.0]; else [world advanceOneTick];
            tick += stride; steps += stride;
            if (!game) [world drainEvents:receive];
            for (NSInteger i=0;i<world.ballCapacity;i++) {
                const PBBall *b=&world.balls[i];
                if (b->state==PBBallInactive || b->captive) continue;
                if (!isfinite(b->position.x)||!isfinite(b->position.y)||!isfinite(b->z)||!isfinite(b->velocity.x)||!isfinite(b->velocity.y)) { invalid=YES; break; }
                if (b->position.x < 0 || b->position.x > table.size.x || b->position.y > table.size.y + table.ballRadius) { invalid=YES; break; }
                if ((tick%8==0 || tick==total) && trace.count<30000) [trace addObject:@[ @(tick), @(i), @(b->position.x), @(b->position.y), @(b->ramp>=0), @(b->state) ]];
                if (b->state!=PBBallFree || (fabsf(b->position.x-table.plunger.position.x)<table.plunger.width*.75f && b->position.y<table.plunger.position.y+table.ballRadius+.03f)) continue;
                NSInteger x=(NSInteger)floor(b->position.x/table.size.x*width), y=(NSInteger)floor(b->position.y/table.size.x*width);
                if (x>=0 && x<width && y>=0 && y<height) {
                    NSInteger cell=((b->ramp>=0)*height+y)*width+x;
                    double dt=(double)stride/960.0;
                    visited[cell]=1; seconds[cell]+=dt; vx[cell]+=b->velocity.x*dt; vy[cell]+=b->velocity.y*dt;
                }
                if (next < (NSInteger)expected.count && (routeBall < 0 || i==routeBall)) {
                    NSDictionary *goal=expected[next];
                    NSArray *region=goal[@"region"];
                    BOOL ramp=[goal[@"layer"] isEqualToString:@"ramp"];
                    if (region && b->state==PBBallFree && (b->ramp>=0)==ramp &&
                        b->position.x>=[region[0] floatValue] && b->position.y>=[region[1] floatValue] &&
                        b->position.x<=[region[2] floatValue] && b->position.y<=[region[3] floatValue]) {
                        routeBall=(int)i; next++;
                        [events addObject:@{ @"event":@"region", @"element":goal[@"id"] ?: @"region",
                            @"ball":@(i), @"tick":@(world.tick), @"position":@[ @(b->position.x), @(b->position.y) ], @"magnitude":@0 }];
                    }
                }
                NSArray *box=spec[@"returnBox"];
                if (box && expected.count && next==(NSInteger)expected.count && i==routeBall && b->state==PBBallFree && b->ramp<0 &&
                    b->position.x>=[box[0] floatValue] && b->position.y>=[box[1] floatValue] &&
                    b->position.x<=[box[2] floatValue] && b->position.y<=[box[3] floatValue] && b->velocity.y<0) returned=YES;
            }
            if (invalid || (!game && (drained || stuck))) break;
        }
    }
    NSMutableArray *cells=[NSMutableArray array];
    for (NSInteger i=0;i<count;i++) if (visited[i]) [cells addObject:@[ @(i), @(seconds[i]), @(vx[i]), @(vy[i]) ]];
    free(seconds); free(vx); free(vy); free(visited);
    NSString *status = invalid ? @"invalid" : stuck ? @"stuck" : (expected.count && next==(NSInteger)expected.count) ? @"success" : drained && !game ? @"drain" : @"timeout";
    return @{ @"id":spec[@"id"], @"seed":@(seed), @"mode":spec[@"mode"], @"status":status,
        @"steps":@(steps), @"seconds":@((double)steps/960), @"wallSeconds":@(Now()-started),
        @"sequenceMatched":@(next), @"returned":@(returned), @"returnMeasured":@(spec[@"returnBox"]!=nil),
        @"events":events, @"trace":trace, @"cells":cells };
}

static NSDictionary *Run(NSDictionary *request) {
    NSError *error=nil;
    NSData *data=[NSData dataWithContentsOfFile:request[@"table"] options:0 error:&error];
    if (!data) return @{ @"error":error.localizedDescription };
    PBTableDefinition *table=[[PBTableDefinition alloc] initWithJSONData:data error:&error];
    if (!table) return @{ @"error":error.localizedDescription ?: @"Invalid table" };
    NSArray *specs=request[@"trials"];
    NSInteger width=[request[@"grid"] integerValue];
    if (width<8 || width>256 || table.size.x<=0 || table.size.y<=0 || table.size.y/table.size.x>8 || !specs.count || specs.count>4096)
        return @{ @"error":@"Invalid grid, table bounds or trial count" };
    NSMutableArray *layout=[NSMutableArray array];
    for (PBLayoutIssue *issue in [PBLayoutValidator issuesForTable:table])
        [layout addObject:@{ @"kind":@(issue.kind), @"first":issue.first ?: @"", @"second":issue.second ?: @"",
            @"amount":@(issue.amount), @"position":@[ @(issue.location.x), @(issue.location.y) ] }];
    NSMutableArray *results=[NSMutableArray array];
    for (NSUInteger i=0;i<specs.count;i++) [results addObject:NSNull.null];
    NSInteger workers=MAX(1, MIN(16, [request[@"workers"] integerValue]));
    double start=Now();
    dispatch_apply((size_t)workers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0), ^(size_t worker) {
        for (NSUInteger i=worker;i<specs.count;i+=(NSUInteger)workers) @autoreleasepool {
            NSDictionary *r=Trial(table,specs[i],width);
            @synchronized(results) { results[i]=r; }
        }
    });
    return @{ @"version":@1, @"table":table.identifier, @"size":@[ @(table.size.x), @(table.size.y) ],
        @"grid":@(width), @"height":@(ceil(table.size.y/table.size.x*width)), @"workers":@(workers),
        @"wallSeconds":@(Now()-start), @"layoutIssues":layout, @"inventory":Inventory(table), @"trials":results,
        @"sampling":@"occupancy fixture:960Hz, autoplay:60Hz approximate; trace fixture:120Hz, autoplay:60Hz" };
}

int main(void) { @autoreleasepool {
    char *line=NULL; size_t size=0;
    while (getline(&line,&size,stdin)>0) @autoreleasepool {
        @try {
            NSData *data=[[@(line) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] dataUsingEncoding:NSUTF8StringEncoding];
            NSError *error=nil;
            id request=[NSJSONSerialization JSONObjectWithData:data options:0 error:&error];
            NSDictionary *result=request ? Run(request) : @{ @"error":error.localizedDescription ?: @"Invalid request" };
            NSData *encoded=[NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&error];
            if (!encoded) encoded=[@"{\"error\":\"Non-finite result\"}" dataUsingEncoding:NSUTF8StringEncoding];
            fwrite(encoded.bytes,1,encoded.length,stdout); fputc('\n',stdout); fflush(stdout);
        } @catch (NSException *e) { puts("{\"error\":\"Invalid request or table\"}"); fflush(stdout); }
    }
    free(line);
} return 0; }
