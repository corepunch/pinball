#import "PBMenuFlow.h"

@implementation PBMenuFlow {
    PBMenuScreen _returnScreen;
}

- (PBMenuCommand)performAction:(PBUIAction)action {
    switch (action) {
        case PBUIPlay:
            if (_screen != PBMenuHome && _screen != PBMenuResults) break;
            _hasActiveGame = YES;
            _screen = PBMenuPlaying;
            return PBMenuStartGame;
        case PBUIPause:
            if (_screen == PBMenuPlaying) _screen = PBMenuPaused;
            break;
        case PBUIResume:
            if (_screen == PBMenuPaused && _hasActiveGame) _screen = PBMenuPlaying;
            break;
        case PBUISettings:
        case PBUIHelp:
            if (_screen != PBMenuHome && _screen != PBMenuPaused && _screen != PBMenuResults) break;
            _returnScreen = _screen;
            _screen = action == PBUISettings ? PBMenuSettings : PBMenuHelp;
            break;
        case PBUIBack:
            if (_screen == PBMenuSettings || _screen == PBMenuHelp) _screen = _returnScreen;
            else if (_screen == PBMenuPaused) _screen = PBMenuPlaying;
            else if (_screen == PBMenuConfirmHome || _screen == PBMenuConfirmRestart) _screen = PBMenuPaused;
            else if (_screen == PBMenuResults) _screen = PBMenuHome;
            break;
        case PBUIHome:
            if (_screen == PBMenuPaused) _screen = PBMenuConfirmHome;
            else if (_screen == PBMenuResults) _screen = PBMenuHome;
            break;
        case PBUIRestart:
            if (_screen == PBMenuPaused) _screen = PBMenuConfirmRestart;
            break;
        case PBUIConfirm:
            if (_screen == PBMenuConfirmRestart) {
                _screen = PBMenuPlaying;
                return PBMenuStartGame;
            }
            if (_screen == PBMenuConfirmHome) {
                _hasActiveGame = NO;
                _screen = PBMenuHome;
                return PBMenuAbandonGame;
            }
            break;
        case PBUICancel:
            if (_screen == PBMenuConfirmHome || _screen == PBMenuConfirmRestart) _screen = PBMenuPaused;
            break;
        default: break;
    }
    return PBMenuNoCommand;
}

- (void)gameDidFinish {
    _hasActiveGame = NO;
    _screen = PBMenuResults;
}

@end
