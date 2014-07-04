package xpc

import (
	"errors"
	_ "fmt"
	"github.com/ugorji/go/codec"
	"log"
	"reflect"
	"strings"
	"sync"
	"unsafe"
)

/*
#include "xpc_wrapper.c"
*/
import "C"

//export ReceivedErrorEvent
func ReceivedErrorEvent(err *C.char) {
	str := C.GoString(err)
	log.Printf("Received Error Event '%s'", str)
}

//export ReceivedPayload
func ReceivedPayload(payload unsafe.Pointer, length C.int) {

	bytes := C.GoBytes(payload, length)

	data := &Payload{}

	decoder := codec.NewDecoderBytes(bytes, &codec.MsgpackHandle{})
	decoder.Decode(data)

	service, mtype, err := locateService(data)

	if err != nil {
		log.Println(err)
		return
	}

	var argv, replyv reflect.Value

	argv = reflect.ValueOf(&data.Args)
	replyv = reflect.New(mtype.ReplyType.Elem())

	go service.call(DefaultService, mtype, argv, replyv)

}

func locateService(data *Payload) (service *service, mtype *methodType, err error) {
	dot := strings.LastIndex(data.Method, ".")

	if dot < 0 {
		err = errors.New("xpc: service/method request ill-formed: " + data.Method)
		return
	}

	serviceName := data.Method[:dot]
	methodName := data.Method[dot+1:]

	// Look up the request.
	DefaultService.mu.RLock()
	service = DefaultService.serviceMap[serviceName]
	DefaultService.mu.RUnlock()

	if service == nil {
		err = errors.New("xpc: can't find service " + data.Method)
		return
	}

	mtype = service.method[methodName]

	if mtype == nil {
		err = errors.New("xpc: can't find method " + data.Method)
	}

	return
}

// service and methodType structs are striaght from
// http://golang.org/src/pkg/net/rpc/server.go
type service struct {
	name   string                 // name of service
	rcvr   reflect.Value          // receiver of methods for the service
	typ    reflect.Type           // type of the receiver
	method map[string]*methodType // registered methods
}

type methodType struct {
	sync.Mutex // protects counters
	method     reflect.Method
	ArgType    reflect.Type
	ReplyType  reflect.Type
	numCalls   uint
}

type XPCService struct {
	mu         sync.RWMutex
	serviceMap map[string]*service
}

type Payload struct {
	Method string        `codec:"method"`
	Args   []interface{} `codec:"args"`
}

func (xpc *XPCService) Start() {
	C.start_xpc()
}

func (xpc *XPCService) CallHost(name string, args []interface{}) {

	p := Payload{Method: name, Args: args}

	bytes := make([]byte, 0)

	encoder := codec.NewEncoderBytes(&bytes, &codec.MsgpackHandle{})
	encoder.Encode(p)

	// why we pass the 1st index:
	// https://coderwall.com/p/m_ma7q
	C.call_host(unsafe.Pointer(&bytes[0]), C.int(len(bytes)))
}

func (s *service) call(xpc *XPCService, mtype *methodType, argv, replyv reflect.Value) {
	mtype.Lock()
	mtype.numCalls++
	mtype.Unlock()

	function := mtype.method.Func

	// Invoke the method, providing a new value for the reply.
	returnValues := function.Call([]reflect.Value{s.rcvr, argv, replyv})

	// The return value for the method is an error.
	errInter := returnValues[0].Interface()
	errmsg := ""

	if errInter != nil {
		errmsg = errInter.(error).Error()
		log.Println(errmsg)
	}

	// TODO Here is where we send our response back, if we have one.
	// need to figure what that looks like.
	// server.sendResponse(sending, req, replyv.Interface(), codec, errmsg)
	// server.freeRequest(req)
}

// Register publishes in the server the set of methods of the
// receiver value that satisfy the following conditions:
//  - exported method
//  - two arguments, both of exported type
//  - the second argument is a pointer
//  - one return value, of type error
// It returns an error if the receiver is not an exported type or has
// no suitable methods. It also logs the error using package log.
// The client accesses each method using a string of the form "Type.Method",
// where Type is the receiver's concrete type.
func (xpc *XPCService) Register(rcvr interface{}) error {
	return xpc.register(rcvr, "", false)
}

func (xpc *XPCService) register(rcvr interface{}, name string, useName bool) error {
	xpc.mu.Lock()
	defer xpc.mu.Unlock()
	if xpc.serviceMap == nil {
		xpc.serviceMap = make(map[string]*service)
	}

	s := new(service)
	s.typ = reflect.TypeOf(rcvr)
	s.rcvr = reflect.ValueOf(rcvr)
	sname := reflect.Indirect(s.rcvr).Type().Name()
	if useName {
		sname = name
	}
	if sname == "" {
		s := "xpc.Register: no service name for type " + s.typ.String()
		log.Print(s)
		return errors.New(s)
	}
	if !isExported(sname) && !useName {
		s := "xpc.Register: type " + sname + " is not exported"
		log.Print(s)
		return errors.New(s)
	}
	if _, present := xpc.serviceMap[sname]; present {
		return errors.New("xpc: service already defined: " + sname)
	}
	s.name = sname

	// Install the methods
	s.method = suitableMethods(s.typ, true)

	if len(s.method) == 0 {
		str := ""

		// To help the user, see if a pointer receiver would work.
		method := suitableMethods(reflect.PtrTo(s.typ), false)
		if len(method) != 0 {
			str = "xpc.Register: type " + sname + " has no exported methods of suitable type (hint: pass a pointer to value of that type)"
		} else {
			str = "xpc.Register: type " + sname + " has no exported methods of suitable type"
		}
		log.Print(str)
		return errors.New(str)
	}
	xpc.serviceMap[s.name] = s
	return nil
}
