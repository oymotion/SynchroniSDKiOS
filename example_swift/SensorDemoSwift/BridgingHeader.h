//
//  BridgingHeader.h
//  SensorDemoSwift — exposes the sensorobjc Objective-C wrapper to Swift.
//  iOS links sensor.xcframework (the headers ship inside the framework);
//  macOS links lib/macos/libsensor.dylib and picks the headers up from the
//  package include directory via the target's HEADER_SEARCH_PATHS.
//

#if __has_include(<sensor/sensorobjc.h>)
#import <sensor/sensorobjc.h>
#else
#import "sensorobjc.h"
#endif
