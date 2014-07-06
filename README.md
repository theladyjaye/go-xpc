# go-xpc

This borrows VERY VERY VERY heavily from the rpc package in
http://golang.org/src/pkg/net/rpc/server.go

It relies on msgpack (github.com/ugorji/go/codec) for it's serialization.

Right now, I just threw this together from some of the other work I have
been doing lately. It works, but it needs some love to be sure; bear with me.

There is a companion XPCConnection (Obj-C) (Swift doesn't have it's XPC
stuff all there at the time of this writing).



Sample usage:

### From Go:

``` go
package main

import (
    "fmt"
    "github.com/aventurella/go-xpc/xpc"
)

type Sample struct{}

func (s *Sample) Test(args *[]interface{}, reply *interface{}) error {
    fmt.Println("CALLED SAMPLE.TEST!!!")
    fmt.Println(args)
    return nil
}

func main() {
    sample := new(Sample)
    xpc.Register(sample)
    xpc.Start()
}
```



### From Cocoa App (Swift):

```swift
import Cocoa

@objc class Foo {

    func Bazzale(args: Array<AnyObject>){
        println("Bazzle Got Args: \(args)")
    }
}

// ... later in some func ...

func initializeXPCService(){
    connection = XPCConnection(name:"com.blitzagency.officebeats-api")
    connection.register(Foo())
    connection.resume()

    connection.call("Sample.Test", withArgs: [1,2,3]) {
        (value) -> () in
        println(value)
    }
}

```


