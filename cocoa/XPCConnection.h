//
//  XPCConnection.h
//  OfficeBeats
//
//  Created by Adam Venturella on 7/2/14.
//  Copyright (c) 2014 BLITZ. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <xpc/xpc.h>
#import "MessagePack.h"

@interface XPCConnection : NSObject

@property (copy) NSString *name;
@property (strong) xpc_connection_t serviceConnection;
@property (strong) xpc_connection_t hostConnection;
@property (strong) dispatch_queue_t hostQueue;
@property (strong) dispatch_queue_t serviceQueue;
@property (strong) NSMutableDictionary *serviceMap;
@property (strong) NSMutableDictionary *keyMap;


- (instancetype) initWithName:(NSString *)name;
- (void)resume;
- (void)host:(xpc_connection_t)connection event:(xpc_object_t)event;
- (void)service:(xpc_connection_t)connection event:(xpc_object_t)event;
- (void)serviceTerminationImminent:(xpc_connection_t) connection;
- (void)serviceConnectionInvalid:(xpc_connection_t) connection;
- (void)serviceConnectionInterrupted:(xpc_connection_t) connection;
- (void)call:(NSString *)method withArgs:(NSArray *)args reply:(void (^)(id))reply;
- (void)register:(id)obj;

@end
