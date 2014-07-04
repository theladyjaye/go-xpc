package xpc

// DefaultServer is the default instance of *Server.
var DefaultService = NewService()

// Register publishes the receiver's methods in the DefaultServer.
func Register(rcvr interface{}) error { return DefaultService.Register(rcvr) }

func Start() { DefaultService.Start() }

func CallHost(name string, args []interface{}) { DefaultService.CallHost(name, args) }

// NewService returns a new XPCService.
func NewService() *XPCService {
	return &XPCService{serviceMap: make(map[string]*service)}
}
