#import <Foundation/Foundation.h>

void SYLog(NSString *level, NSString *event, NSDictionary *fields);
NSDictionary *SYError(NSError *error);
bool sy_log_init(const char *directory);
void sy_log_json(const char *level, const char *event, const char *fields);
void sy_log_flush(void);
