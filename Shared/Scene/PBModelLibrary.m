#import "PBModelLibrary.h"

@implementation PBModelLibrary {
    NSBundle *_bundle;
    NSString *_directory;
    NSMutableDictionary<NSString *, SCNNode *> *_templates;
}

- (instancetype)initWithBundle:(NSBundle *)bundle kit:(NSString *)kit {
    if ((self = [super init])) {
        _bundle = bundle;
        _directory = [@"GameData/Models" stringByAppendingPathComponent:kit];
        _templates = [NSMutableDictionary dictionary];
    }
    return self;
}

- (SCNNode *)nodeNamed:(NSString *)name {
    SCNNode *model = _templates[name];
    if (!model) {
        NSURL *url = [_bundle URLForResource:name withExtension:@"dae" subdirectory:_directory];
        if (!url) return nil;
        NSError *error;
        // Export is already Y-up/metres; preserve its semantic material names and normals.
        SCNScene *scene = [SCNScene sceneWithURL:url options:@{SCNSceneSourceConvertToYUpKey:@NO} error:&error];
        if (!scene) { NSLog(@"Could not load model %@: %@", name, error); return nil; }
        model = [SCNNode node];
        model.name = name;
        for (SCNNode *child in [scene.rootNode.childNodes copy]) [model addChildNode:child];
        _templates[name] = model;
    }
    SCNNode *node = [model clone];
    // SCNNode.clone shares geometry. Each bumper needs its own material selection.
    [node enumerateChildNodesUsingBlock:^(SCNNode *child, BOOL *stop) {
        if (child.geometry) child.geometry = [child.geometry copy];
    }];
    return node;
}
@end
