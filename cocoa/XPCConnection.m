//
//  XPCConnection.m
//  OfficeBeats
//
//  Created by Adam Venturella on 7/2/14.
//  Copyright (c) 2014 BLITZ. All rights reserved.
//

#import "XPCConnection.h"
#import <objc/runtime.h>
#import <objc/message.h>

typedef id dynamic_action(id, Method, NSArray *);

#pragma mark - XPCMethod
@interface XPCMethod: NSObject
@property(assign) Method method;
@property(assign) NSUInteger numArgs;
@property(assign) SEL selector;
@end

@implementation XPCMethod
@end

#pragma mark - XPCService
@interface XPCService: NSObject
@property(copy) NSString *name;
@property(strong) id rcvr;
@property(strong) NSMutableDictionary* method ;
@end

@implementation XPCService
- (instancetype) init{
    self = [super init];
    
    if(self){
        self.method = [[NSMutableDictionary alloc] init];
    }
    
    return self;
}
@end


#pragma mark - XPCPayload
@interface XPCPayload: NSObject
@property(copy) NSString *method;
@property(copy) NSArray *args;
@end

@implementation XPCPayload
@end


#pragma mark - XPCConnection (Private)
@interface XPCConnection (Private)

- (xpc_connection_t)createConnection:(NSString *)name queue:(dispatch_queue_t)queue;
- (void)prepareConnection:(xpc_connection_t)connection;
- (void)initializeServiceConnection;
- (void)initializeHostConnection;
- (void)host:(XPCPayload *)payload;

@end

#pragma mark - XPCConnection
@implementation XPCConnection

- (instancetype)initWithName:(NSString *)name
{
    self = [super init];
    
    if(self){
        self.name = name;
        self.serviceMap = [[NSMutableDictionary alloc] init];
        self.keyMap = [[NSMutableDictionary alloc] init];
    }
    
    return self;
}

- (void)register:(id)obj
{
    Class cls  = [obj class];
    NSString *className = [NSString stringWithUTF8String:class_getName(cls)];
    NSString * key;
    
    // Swift will mangle the names of classes made available to it:
    // http://stackoverflow.com/a/24329118/1060314
    // _TtC$$AppName%%ClassName
    
    NSString *prefix = @"_TtC";
    
    if([className hasPrefix:prefix]){
        NSString *appName = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleName"];
        
        NSUInteger index = 0;
        NSString *length = [NSString stringWithFormat:@"%lu", (unsigned long)[appName length]];
        
        index = index + [prefix length] + [length length] + [appName length];
        
        NSString *stage1 = [className substringFromIndex:index];
        NSString *stage2;
        NSScanner *scanner = [NSScanner scannerWithString:stage1];
        [scanner scanInteger:NULL];
        [scanner scanCharactersFromSet:[NSCharacterSet alphanumericCharacterSet] intoString:&stage2];
        
        key = stage2;
    } else {
        key = className;
    }
    
    self.keyMap[key] = className;
    
    if(self.serviceMap[className] != nil){
        return;
    }
    
    XPCService *service = [[XPCService alloc] init];
    service.name = key;
    service.rcvr = obj;

    uint methodCount;
    Method *methods = class_copyMethodList(cls, &methodCount);
    
    for (int i=0; i < methodCount; i++){
        
        Method method = methods[i];
        NSString *methodName = NSStringFromSelector(method_getName(method));
        
        // TODO: right now we just blindly assume the 1st arg will be an array
        //
        // char buffer[256];
        // method_getArgumentType(method, 0, buffer, 256);
        // could help alleviate that.
        //
        // all our methods that qualify should conform to the following:
        // arg 0: Array
        // arg 1: Pointer to the return value.
        // return error
        // ^ matches go side of things.
        // This is not implemented yet.
        
        XPCMethod *m = [[XPCMethod alloc] init];
        m.method = method;
        m.numArgs = method_getNumberOfArguments(method);
        m.selector = NSSelectorFromString(methodName);
        
        service.method[methodName] = m;
    }
    
    self.serviceMap[className] = service;
}


- (void)call:(NSString *)method withArgs:(NSArray *)args reply:(void (^)(id))reply
{
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    NSDictionary *obj = [NSDictionary dictionaryWithObjects:@[method, args]
                                                        forKeys:@[@"method", @"args"]];
    
    NSData *data = [obj messagePack];
    xpc_object_t payload = xpc_data_create([data bytes], [data length]);
    
    xpc_dictionary_set_value(message, "payload", payload);
    
    if(reply){
        
        xpc_dictionary_set_bool(message, "reply", true);
        
        void (^response)(xpc_object_t) = ^(xpc_object_t value){
            
            NSUInteger length;
            const void * responseBytes = xpc_dictionary_get_data(value, "payload", &length);
        
            NSData *responseData = [NSData dataWithBytes:responseBytes length:length];
            reply([responseData messagePackParse]);
        };
        
        xpc_connection_send_message_with_reply(self.serviceConnection,
                                               message, self.serviceQueue,
                                               response);
    }
}

- (void)resume
{
    [self initializeServiceConnection];
    [self initializeHostConnection];
    
    // send the service a reference back to this host
    // so it can connect to us.
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(message, "endpoint", xpc_endpoint_create(self.hostConnection));
    xpc_connection_send_message(self.serviceConnection, message);
}


- (void)initializeHostConnection
{
    NSString *queueName = [self.name stringByAppendingString:@"-host"];
    self.hostQueue = dispatch_queue_create([queueName UTF8String], NULL);
    
    // we want an anonymous connection, so we pass nil
    // for the service name.
    self.hostConnection = [self createConnection:nil queue:self.hostQueue];
    
    xpc_connection_set_event_handler(self.hostConnection, ^(xpc_object_t event) {
        [self host:self.hostConnection event:event];
    });
    
    xpc_connection_resume(self.hostConnection);
}

- (void)initializeServiceConnection
{
    // represents our connection TO the XPC service.
    // allows us to send information to the XPC Service.
    // this must be initialized first prior to sending
    // a host connection to the service to enable the XPC
    // service to talk back to us.
    NSString *queueName = [self.name stringByAppendingString:@"-service"];
    self.serviceQueue = dispatch_queue_create([queueName UTF8String], NULL);
    
    self.serviceConnection = [self createConnection:self.name queue:self.serviceQueue];
    
    xpc_connection_set_event_handler(self.serviceConnection, ^(xpc_object_t event) {
        [self service:self.serviceConnection event:event];
    });
    
    xpc_connection_resume(self.serviceConnection);
}

- (xpc_connection_t)createConnection:(NSString *)name queue:(dispatch_queue_t)queue
{
    xpc_connection_t result;

    if (!name){
        result = xpc_connection_create(NULL, queue);
    } else {
        const char * serviceName = [name UTF8String];
        result = xpc_connection_create(serviceName, queue);
    }
    
    return result;
}


- (void)host:(xpc_connection_t)connection event:(xpc_object_t)event
{
    xpc_type_t type = xpc_get_type(event);
    
    if (type == XPC_TYPE_CONNECTION) {
        // handle messages sent FROM the service back to us:
        xpc_connection_t peer = (xpc_connection_t) event;
        
        char *queue_name = NULL;
        
        // make a unique queue for the event handler
        // so we are left with a 1:1 relationship between
        // these connections
        asprintf(&queue_name,
                 "%s-peer-%d",
                 [self.name UTF8String],
                 xpc_connection_get_pid(peer));
        
        dispatch_queue_t peer_event_queue = dispatch_queue_create(queue_name, NULL);
        free(queue_name);
        
        xpc_connection_set_target_queue(peer, peer_event_queue);
        xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
            xpc_type_t type = xpc_get_type(event);
            
            if(type == XPC_TYPE_DICTIONARY){
                
                NSUInteger length;
                const void *bytes = xpc_dictionary_get_data(event, "payload", &length);
                
                NSData *data = [NSData dataWithBytes:bytes length:length];
                NSDictionary *obj = (NSDictionary *)[data messagePackParse];
                
                XPCPayload *payload = [[XPCPayload alloc] init];
                payload.method = obj[@"method"];
                payload.args = obj[@"args"];
                
                [self host:payload];
            }
        });
        
        xpc_connection_resume(peer);
    }
}

- (void)host:(XPCPayload *)payload
{
    NSArray *parts  = [payload.method componentsSeparatedByString:@"."];
    NSString *key = self.keyMap[parts[0]];
    
    if(!key) return;

    XPCService *service = self.serviceMap[key];
    
    if(!service) return;
    
    XPCMethod *method = service.method[parts[1]];

    if(!method) return;
    
    // method_invoke must be cast to an appropriate function pointer type
    // before being called.
    ((dynamic_action*) method_invoke) (service.rcvr, method.method, payload.args);
}

- (void)service:(xpc_connection_t)connection event:(xpc_object_t)event
{
    xpc_type_t type = xpc_get_type(event);
    
    if (type == XPC_TYPE_ERROR) {
        if (event == XPC_ERROR_TERMINATION_IMMINENT) {
            [self serviceTerminationImminent: connection];
        } else if (event == XPC_ERROR_CONNECTION_INVALID) {
            [self serviceConnectionInvalid: connection];
        } else if (event == XPC_ERROR_CONNECTION_INTERRUPTED){
            [self serviceConnectionInterrupted: connection];
        }
    }
}

- (void)serviceConnectionInterrupted:(xpc_connection_t) connection
{
    // The service has either cancaled itself, crashed, or been
    // terminated.  The XPC connection is still valid and sending a
    // message to it will re-launch the service.  If the service is
    // state-full, this is the time to initialize the new service.
    NSLog(@"received XPC_ERROR_CONNECTION_INTERRUPTED");
}

- (void)serviceTerminationImminent:(xpc_connection_t) connection
{
    NSLog(@"received XPC_ERROR_TERMINATION_IMMINENT");
}

- (void)serviceConnectionInvalid:(xpc_connection_t) connection
{
    // The service is invalid. Either the service name supplied to
    // xpc_connection_create() is incorrect or we (this process) have
    // canceled the service; we can do any cleanup of appliation
    // state at this point.
    
    NSLog(@"received XPC_ERROR_CONNECTION_INVALID");
    self.serviceConnection = nil;
}
@end
