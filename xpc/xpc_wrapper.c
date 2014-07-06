//
//  xpc_wrapper.c
//
//  Created by Adam Venturella on 7/3/14.
//

#ifndef xpc_impl
#define xpc_impl
#include <stdio.h>
#include <xpc/xpc.h>

struct PayloadResult{
    int length;
    void *bytes;
};


extern void ReceivedErrorEvent(char* err);
extern struct PayloadResult ReceivedPayload(void *payload, int length);

static xpc_connection_t host_connection;
static dispatch_queue_t payloadQueue;


static xpc_connection_t initialize_host_connection(xpc_object_t event)
{
    xpc_connection_t connection = xpc_dictionary_create_connection(event, "endpoint");

    xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
        xpc_type_t type = xpc_get_type(event);

        if (XPC_TYPE_ERROR == type &&
            XPC_ERROR_CONNECTION_INTERRUPTED == event) {
            // the app has gone away here.
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
            ReceivedErrorEvent("XPC_ERROR_CONNECTION_INVALID");
            cleanup();

        } else if (event == XPC_ERROR_TERMINATION_IMMINENT) {
            // Handle per-connection termination cleanup.
            ReceivedErrorEvent("XPC_ERROR_TERMINATION_IMMINENT");
            cleanup();
        }
    } else {


        xpc_object_t endpoint =  xpc_dictionary_get_value(event, "endpoint");

        if(endpoint){
            host_connection = initialize_host_connection(event);
            xpc_connection_resume(host_connection);
            return;
        }

        int64_t length;
        const void *bytes = xpc_dictionary_get_data(event, "payload", (size_t *)&length);
        bool shouldReply = xpc_dictionary_get_bool(event, "reply");

        xpc_object_t reply;

        if(shouldReply){
            reply = xpc_dictionary_create_reply(event);
        }

        dispatch_async(payloadQueue, ^{

            struct PayloadResult result = ReceivedPayload((void*)bytes, length);

            dispatch_async(payloadQueue, ^{

                if(shouldReply){
                    xpc_object_t payload = xpc_data_create(result.bytes, (uint) result.length);
                    xpc_dictionary_set_value(reply, "payload", payload);
                    xpc_connection_send_message(peer, reply);
                }
            });
        });
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
    payloadQueue = dispatch_queue_create("com.go-xpc.payloads", NULL);
    xpc_main(event_handler);
}
#endif
