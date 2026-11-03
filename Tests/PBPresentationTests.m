#import <XCTest/XCTest.h>
#import "PBTablePresentation.h"
#import "PBLayoutValidator.h"
#import "PBPhysicsWorld.h"

@interface PBPresentationTests : XCTestCase
@end

@implementation PBPresentationTests
- (void)testMiniPinballScaleIsConsistentAcrossPhoneSizes {
    NSString *root = [[@(__FILE__) stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:
        [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"GameData/Tables/aurora.json"]] error:NULL];
    XCTAssertEqualWithAccuracy(table.size.y,1.6,.00001);
    const CGSize phones[] = {{320,568},{375,667},{402,874},{440,956}};
    for (NSUInteger i=0;i<4;i++) {
        CGSize size = phones[i]; CGFloat top=i<2?20:62, bottom=i<2?0:34;
        CGPoint a=PBTableScreenPoint(table.size,size,top,bottom,0,0);
        CGPoint b=PBTableScreenPoint(table.size,size,top,bottom,simd_make_float2(table.ballRadius*2,0),0);
        XCTAssertEqualWithAccuracy((b.x-a.x)/size.width,1.0/15,.002,@"ball remains readable on every phone");
        for (PBEdgeDef *target in table.dropTargets) {
            CGPoint start=PBTableScreenPoint(table.size,size,top,bottom,target.a,0);
            CGPoint end=PBTableScreenPoint(table.size,size,top,bottom,target.b,0);
            XCTAssertGreaterThanOrEqual(hypot(end.x-start.x,end.y-start.y)/size.width,.08);
        }
    }
}

- (void)testPhonesUseTheFullWidthWithoutReservingSpaceForTheHUD {
    const CGSize sizes[] = {{320, 568}, {375, 667}, {390, 844}, {402, 874}, {440, 956}};
    const CGFloat tops[] = {20, 20, 47, 62, 62};
    const CGFloat bottoms[] = {0, 0, 34, 34, 34};
    simd_float2 board = simd_make_float2(1, 1.9);
    for (NSUInteger i = 0; i < 5; i++) {
        CGSize size = sizes[i];
        PBGameViewLayout layout = PBGameViewLayoutMake(size, tops[i], bottoms[i]);
        XCTAssertGreaterThanOrEqual(CGRectGetMinY(layout.header), tops[i]);
        XCTAssertTrue(CGRectContainsRect(layout.header, layout.pause));
        XCTAssertEqualWithAccuracy(layout.header.size.height, 44 * layout.scale, .001, @"one-row HUD");
        XCTAssertEqualWithAccuracy(layout.board.origin.y, 0, .001, @"world extends behind the HUD and notch");
        XCTAssertEqualWithAccuracy(layout.board.origin.x, 0, .001);
        XCTAssertEqualWithAccuracy(layout.board.size.width, size.width, .001);
        const simd_float2 points[] = {{0, 0}, {1, 0}, {0, 1.9}, {1, 1.9}, {.962, .1}};
        for (NSUInteger j = 0; j < 5; j++) {
            CGPoint p = PBTableScreenPoint(board, size, tops[i], bottoms[i], points[j], 0);
            XCTAssertGreaterThanOrEqual(p.x, CGRectGetMinX(layout.board) - .001);
            XCTAssertLessThanOrEqual(p.x, CGRectGetMaxX(layout.board) + .001);
            XCTAssertGreaterThanOrEqual(p.y, CGRectGetMinY(layout.board) - .001);
            XCTAssertLessThanOrEqual(p.y, CGRectGetMaxY(layout.board) + .001);
        }
    }
}

- (void)testModernPhoneUsesAlmostAllTheWidthAndZoomsPastTheOldFrame {
    CGSize view = CGSizeMake(402, 874);
    simd_float2 board = simd_make_float2(1, 1.9);
    PBTableCameraFrame frame = PBTableCameraFrameMake(board, view, 59, 34);
    CGFloat drawnWidth = view.height / frame.visibleHeight;
    XCTAssertGreaterThan(drawnWidth / view.width, .97);
    XCTAssertLessThan(frame.visibleHeight, 2.29, @"the old camera left more unused surround");
}

- (void)testOrthographicPartsHaveTheSameScaleAtEveryHeightAndAcrossTheBoard {
    CGSize view = CGSizeMake(402, 874);
    simd_float2 board = simd_make_float2(1, 1.9);
    for (NSUInteger i = 0; i < 3; i++) {
        float y = .3f + i * .6f;
        CGPoint a = PBTableScreenPoint(board, view, 59, 34, simd_make_float2(.2, y), 0);
        CGPoint b = PBTableScreenPoint(board, view, 59, 34, simd_make_float2(.3, y), 0);
        CGPoint raisedA = PBTableScreenPoint(board, view, 59, 34, simd_make_float2(.2, y), .2);
        CGPoint raisedB = PBTableScreenPoint(board, view, 59, 34, simd_make_float2(.3, y), .2);
        XCTAssertEqualWithAccuracy(b.x - a.x, raisedB.x - raisedA.x, .0001);
        XCTAssertEqualWithAccuracy(a.x, raisedA.x, .0001);
        XCTAssertEqualWithAccuracy(raisedA.y, a.y, .001, @"flat sprite projection ignores height");
        simd_float2 projected = PBTableProject(board, simd_make_float2(.02, .04), simd_make_float2(.2, y), .2);
        CGPoint equivalent = PBTableScreenPoint(board, view, 59, 34, projected, 0);
        XCTAssertEqualWithAccuracy(equivalent.y, raisedA.y, .0001, @"authoring and runtime use the same camera");
    }
}

- (void)testChangingTheTopSafeAreaMovesOnlyTheOverlay {
    CGSize view = CGSizeMake(402, 874);
    PBGameViewLayout notch = PBGameViewLayoutMake(view, 47, 34);
    PBGameViewLayout island = PBGameViewLayoutMake(view, 62, 34);
    XCTAssertEqualWithAccuracy(island.header.origin.y - notch.header.origin.y, MAX(54, 62) - MAX(54, 47), .001);
    CGPoint notchTop = PBTableScreenPoint(simd_make_float2(1, 1.9), view, 47, 34, simd_make_float2(.5, 1.9), 0);
    CGPoint islandTop = PBTableScreenPoint(simd_make_float2(1, 1.9), view, 62, 34, simd_make_float2(.5, 1.9), 0);
    XCTAssertEqualWithAccuracy(islandTop.y, notchTop.y, .001, @"the notch must not shrink or shift the world");
}
- (void)testDisplayBoundaryReachesTheScreenWithRoundedTopCorners {
    simd_float2 size = simd_make_float2(1, 1.9);
    const CGSize views[] = {{393, 852}, {402, 874}, {440, 956}};
    for (NSInteger v = 0; v < 3; v++) {
        CGSize view = views[v];
        CGFloat top = v == 0 ? 59 : 62;
        PBPointList *edge = PBTableDisplayBoundary(size, view, top, 34, .03, .006);
        CGFloat radius = PBDisplayCornerRadius(view, top, 34);
        CGFloat inset = -.006 * view.height / PBTableCameraFrameMake(size, view, top, 34).visibleHeight;
        CGFloat curve = radius - inset;
        for (NSInteger i = 1; i <= 17; i++) {
            simd_float2 p = edge.points[i];
            CGPoint screen = PBTableScreenPoint(size, view, top, 34, p, .03);
            XCTAssertEqualWithAccuracy(hypot(screen.x - (view.width - radius), screen.y - radius), curve, .001);
        }
        simd_float2 right = edge.points[1], topRight = edge.points[17], topLeft = edge.points[18];
        XCTAssertEqualWithAccuracy(PBTableScreenPoint(size, view, top, 34, right, .03).x, view.width - inset, .001);
        XCTAssertEqualWithAccuracy(PBTableScreenPoint(size, view, top, 34, topRight, .03).y, inset, .001);
        XCTAssertEqualWithAccuracy(topRight.y, topLeft.y, .0001, @"unbroken top edge: no Dynamic Island collider");
        simd_float2 original = simd_make_float2(.37, 1.1);
        CGPoint screen = PBTableScreenPoint(size, view, top, 34, original, .08);
        simd_float2 roundTrip = PBTablePointFromScreen(size, view, top, 34, screen, .08);
        XCTAssertLessThan(simd_distance(original, roundTrip), .00001);
    }
}

- (void)testBallBouncesAtScreenTopAndCornerAfterResizing {
    NSString *path = [@(__FILE__) stringByDeletingLastPathComponent];
    path = [[path stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"GameData/Tables/aurora.json"];
    PBTableDefinition *table = [[PBTableDefinition alloc] initWithJSONData:[NSData dataWithContentsOfFile:path] error:NULL];
    XCTAssertNotNil(table);
    PBPhysicsWorld *world = [[PBPhysicsWorld alloc] initWithTable:table];
    NSInteger ball = [world spawnBallAtPlunger];
    const CGSize views[] = {{402, 874}, {440, 956}, {393, 852}};
    for (NSInteger v = 0; v < 3; v++) {
        CGSize view = views[v];
        [world fitDisplayBoundaryToViewSize:view topInset:62 bottomInset:34];
        // No hardware occupies this extension above the authored table.
        simd_float2 p = PBTablePointFromScreen(table.size, view, 62, 34, CGPointMake(view.width * .5, 32), table.ballRadius);
        [world placeBall:ball at:p velocity:simd_make_float2(0, 1)];
        for (NSInteger i = 0; i < 100; i++) [world advanceOneTick];
        XCTAssertLessThan(world.balls[ball].velocity.y, 0, @"top bounces even above the old grid height");
        p = PBTablePointFromScreen(table.size, view, 62, 34, CGPointMake(view.width - 40, 40), table.ballRadius);
        [world placeBall:ball at:p velocity:simd_make_float2(1, 1)];
        for (NSInteger i = 0; i < 80; i++) [world advanceOneTick];
        XCTAssertLessThan(world.balls[ball].velocity.x, 0, @"rounded corner turns the ball inward");
        XCTAssertLessThan(world.balls[ball].velocity.y, 0);
    }
}
@end
