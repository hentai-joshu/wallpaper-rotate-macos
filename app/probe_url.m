#import <Cocoa/Cocoa.h>
int main(void) { @autoreleasepool {
  int i = 0;
  for (NSScreen *s in [NSScreen screens]) {
    NSURL *u = [[NSWorkspace sharedWorkspace] desktopImageURLForScreen:s];
    printf("[%d] name=%s frame=%.0fx%.0f  %s\n", i++, s.localizedName.UTF8String,
      s.frame.size.width, s.frame.size.height, u.path.UTF8String ?: "(nil)");
  }
  printf("main: %s\n", [NSScreen mainScreen].localizedName.UTF8String ?: "?");
} return 0; }
