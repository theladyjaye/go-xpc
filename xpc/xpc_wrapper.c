//
//  xpc_wrapper.c
//  cableknit_xpc_s3_upload
//
//  Created by Adam Venturella on 4/5/14.
//  Copyright (c) 2014 BLITZ. All rights reserved.
//

#ifndef xpc_impl
#define xpc_impl
#include <stdio.h>
#include <xpc/xpc.h>
#include <asl.h>

extern void ReceivedErrorEvent(char* err);
extern void ReceivedPayload(void *payload, int length);

static xpc_connection_t host_connection;

static xpc_connection_t initialize_host_connection(xpc_object_t event)
{
    xpc_connection_t connection = xpc_dictionary_create_connection(event, "endpoint");

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        xpc_type_t type = xpc_get_type(event);

        // If the remote end of this connection has gone away then stop download
        if (XPC_TYPE_ERROR == type &&
            XPC_ERROR_CONNECTION_INTERRUPTED == event) {
            // the app has gone away here.
            asl_log(NULL, NULL, ASL_LEVEL_NOTICE, "APP HAS GONE AWAY!!!\n");
        }
    });

    return connection;
}

static void cleanup()
{
    if(host_connection){
        xpc_release(host_connection);
    }
}

static void call_host(void *bytes, int len)
{
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);

    xpc_object_t payload = xpc_data_create(bytes, len);
    xpc_object_t length = xpc_int64_create(len);

    xpc_dictionary_set_value(message, "payload", payload);
    xpc_dictionary_set_value(message, "length", length);

    if(!host_connection){
        asl_log(NULL, NULL, ASL_LEVEL_NOTICE, "NO HOST CONNECTION!\n");
    }

    xpc_connection_send_message(host_connection, message);
}

static void peer_event_handler(xpc_connection_t peer, xpc_object_t event)
{
    xpc_type_t type = xpc_get_type(event);

    if (type == XPC_TYPE_ERROR) {
        if (event == XPC_ERROR_CONNECTION_INVALID) {
            // The client process on the other end of the connection has either
            // crashed or cancelled the connection. After receiving this error,
            // the connection is in an invalid state, and you do not need to
            // call xpc_connection_cancel(). Just tear down any associated state
            // here.
            asl_log(NULL, NULL, ASL_LEVEL_NOTICE, "XPC_ERROR_CONNECTION_INVALID\n");

            ReceivedErrorEvent("XPC_ERROR_CONNECTION_INVALID");
            cleanup();

        } else if (event == XPC_ERROR_TERMINATION_IMMINENT) {
            // Handle per-connection termination cleanup.
            asl_log(NULL, NULL, ASL_LEVEL_NOTICE, "XPC_ERROR_TERMINATION_IMMINENT\n");

            ReceivedErrorEvent("XPC_ERROR_TERMINATION_IMMINENT");
            cleanup();
        }
    } else {


        xpc_object_t endpoint =  xpc_dictionary_get_value(event, "endpoint");

        if(endpoint){
            asl_log(NULL, NULL, ASL_LEVEL_NOTICE, "Received Event: Connection\n");

            host_connection = initialize_host_connection(event);
            asl_log(NULL, NULL, ASL_LEVEL_NOTICE, "Establishing Host Connection\n");
            xpc_connection_resume(host_connection);
            return;
        }

        asl_log(NULL, NULL, ASL_LEVEL_NOTICE, "Received Event: Payload\n");
        int64_t length = xpc_dictionary_get_int64(event, "length");
        const void *bytes = xpc_dictionary_get_data(event, "payload", (size_t *)&length);

        ReceivedPayload((void*)bytes, length);
    }
}

static void event_handler(xpc_connection_t peer)
{
    // By defaults, new connections will target the default dispatch
    // concurrent queue.
    xpc_connection_set_event_handler(peer, ^(xpc_object_t event) {
        peer_event_handler(peer, event);
    });

    // This will tell the connection to begin listening for events. If you
    // have some other initialization that must be done asynchronously, then
    // you can defer this call until after that initialization is done.
    xpc_connection_resume(peer);
}


static void start_xpc()
{
    //handler_resolve = resolve;
    //handler_reject = reject;
    xpc_main(event_handler);
}


#endif
