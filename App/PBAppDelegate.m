//
//  PBAppDelegate.m
//

#import "PBAppDelegate.h"
#import "PBGameViewController.h"

@implementation PBAppDelegate

- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *configuration = [UISceneConfiguration configurationWithName:@"Default" sessionRole:session.role];
    configuration.delegateClass = [PBSceneDelegate class];
    return configuration;
}

@end

@implementation PBSceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [PBGameViewController new];
    [self.window makeKeyAndVisible];
}

@end
