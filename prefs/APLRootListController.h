//
// Created by AT5HK
//

#import <Preferences/PSListController.h>
#import "Common.h"
#import "PasswordViewController.h"

#define IS_ENABLED_CELL_INDEXPATH [NSIndexPath indexPathForRow:0 inSection:0]
#define BIOMETRIC_CELL_INDEXPATH [NSIndexPath indexPathForRow:1 inSection:0]
#define PASSCODE_CELL_INDEXPATH [NSIndexPath indexPathForRow:2 inSection:0]

@interface APLRootListController : PSListController <UIAdaptivePresentationControllerDelegate> {
    UITableView *_table;
}

@end
