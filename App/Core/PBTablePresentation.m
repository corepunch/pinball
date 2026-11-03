#import "PBTablePresentation.h"
#import "PBTableDefinition.h"

const float PBTableCameraTilt = 20.0f;

static CGSize PBValidViewSize(CGSize view) {
    return isfinite(view.width) && isfinite(view.height) && view.width > 0 && view.height > 0 ? view : CGSizeMake(402, 874);
}

PBGameViewLayout PBGameViewLayoutMake(CGSize view, CGFloat topInset, CGFloat bottomInset) {
    view = PBValidViewSize(view);
    CGFloat scale = view.width / 402.0;
    CGFloat top = isfinite(topInset) ? MAX(0, topInset) : 0;
    CGFloat bottom = isfinite(bottomInset) ? MAX(0, bottomInset) : 0;
    // Art is full bleed. Only controls and readable text need the safe-area reservation.
    top = MIN(top, view.height * .25);
    bottom = MIN(bottom, view.height * .25);
    // Match the reference's native large-title row: 20-point side margins and
    // a centre 76 points from the top on the 402-point authoring canvas. Taller
    // Dynamic Island safe areas can move the whole row down together.
    CGFloat headerTop = MAX(54 * scale, top);
    CGRect header = CGRectMake(20 * scale, headerTop, view.width - 40 * scale, 44 * scale);
    CGRect pause = CGRectMake(header.origin.x + header.size.width - 44 * scale,
                              header.origin.y, 44 * scale, 44 * scale);
    // HUD floats over the world: no reserved header strip, even on short phones.
    CGFloat boardTop = 0;
    CGFloat boardBottom = view.height - MAX(8 * scale, bottom * .5);
    CGRect board = CGRectMake(0, boardTop, view.width,
                              MAX(1, boardBottom - boardTop));
    return (PBGameViewLayout){header, pause, board, scale};
}

simd_float2 PBTablePointFromScreen(simd_float2 size, CGSize view, CGFloat top, CGFloat bottom, CGPoint point, float height) {
    view = PBValidViewSize(view);
    PBTableCameraFrame frame = PBTableCameraFrameMake(size, view, top, bottom);
    float tilt = PBTableCameraTilt * (float)M_PI / 180.0f;
    CGFloat unit = view.height / frame.visibleHeight;
    return simd_make_float2(size.x * .5f + (point.x - view.width * .5) / unit,
        frame.centerY + ((view.height * .5 - point.y) / unit - height * sinf(tilt)) / cosf(tilt));
}

CGFloat PBDisplayCornerRadius(CGSize view, CGFloat top, CGFloat bottom) {
    view = PBValidViewSize(view);
    if (bottom <= 0) return 0; // Rectangular Home-button display.
    return MIN(view.width * .16, MAX(bottom, top * .9));
}

PBPointList *PBTableDisplayBoundary(simd_float2 size, CGSize view, CGFloat top, CGFloat bottom,
                                          float ballRadius, float wallRadius) {
    view = PBValidViewSize(view);
    PBTableCameraFrame frame = PBTableCameraFrameMake(size, view, top, bottom);
    CGFloat unit = view.height / frame.visibleHeight;
    // Mesh and physics share one radius. Put the invisible wall's inner face
    // at the display edge, rather than leaving a wall-thickness gap there.
    CGFloat inset = -wallRadius * unit;
    CGFloat radius = PBDisplayCornerRadius(view, top, bottom);
    CGFloat curve = MAX(0, radius - inset);
    PBPointList *points = [[PBPointList alloc] initWithCount:36];
    __block NSInteger index = 0;
    void (^add)(CGPoint) = ^(CGPoint p) {
        simd_float2 q = PBTablePointFromScreen(size, view, top, bottom, p, ballRadius);
        [points mutablePoints][index++] = q;
    };
    // Lower corners sit behind the existing apron; no line closes the drain.
    CGFloat lower = PBTableScreenPoint(size, view, top, bottom, simd_make_float2(0, -.01), ballRadius).y;
    add(CGPointMake(view.width - inset, lower));
    for (NSInteger i = 0; i <= 16; i++) {
        CGFloat a = (CGFloat)i / 16 * M_PI_2;
        add(CGPointMake(view.width - radius + curve * cos(a), radius - curve * sin(a)));
    }
    for (NSInteger i = 0; i <= 16; i++) {
        CGFloat a = M_PI_2 + (CGFloat)i / 16 * M_PI_2;
        add(CGPointMake(radius + curve * cos(a), radius - curve * sin(a)));
    }
    add(CGPointMake(inset, lower));
    return points;
}

PBTableCameraFrame PBTableCameraFrameMake(simd_float2 size, CGSize view, CGFloat top, CGFloat bottom) {
    view = PBValidViewSize(view);
    PBGameViewLayout layout = PBGameViewLayoutMake(view, top, bottom);
    float cosine = cosf(PBTableCameraTilt * (float)M_PI / 180.0f);
    CGFloat pixelsPerUnit = MIN(layout.board.size.width / MAX(size.x, .01f),
                                layout.board.size.height / MAX(size.y * cosine, .01f));
    float visible = (float)(view.height / pixelsPerUnit);
    // Anchor the near edge above the home indicator, rather than centering extra air below it.
    float center = (float)((layout.board.origin.y + layout.board.size.height - view.height * .5) / (pixelsPerUnit * cosine));
    return (PBTableCameraFrame){visible, center};
}

CGPoint PBTableScreenPoint(simd_float2 size, CGSize view, CGFloat top, CGFloat bottom, simd_float2 point, float height) {
    view = PBValidViewSize(view);
    PBTableCameraFrame frame = PBTableCameraFrameMake(size, view, top, bottom);
    float tilt = PBTableCameraTilt * (float)M_PI / 180.0f;
    CGFloat unit = view.height / frame.visibleHeight;
    return CGPointMake(view.width * .5 + (point.x - size.x * .5) * unit,
                       view.height * .5 - ((point.y - frame.centerY) * cosf(tilt) + height * sinf(tilt)) * unit);
}
