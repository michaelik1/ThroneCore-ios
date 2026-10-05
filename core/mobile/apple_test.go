package mobile

import (
	"errors"
	"net/netip"
	"os"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/sagernet/sing-box/adapter"
	"github.com/sagernet/sing-box/log"
	"github.com/sagernet/sing/common/control"
)

type testApplePlatform struct {
	underNE        bool
	includeAll     bool
	openErr        error
	openOptions    TunOptions
	access         sync.Mutex
	monitorStarts  int
	monitorCloses  int
	interfaceReads int
	listener       InterfaceUpdateListener
}

func (p *testApplePlatform) OpenTun(options TunOptions) (int32, error) {
	p.openOptions = options
	return 42, p.openErr
}

func (p *testApplePlatform) StartDefaultInterfaceMonitor(listener InterfaceUpdateListener) error {
	p.access.Lock()
	p.monitorStarts++
	p.listener = listener
	p.access.Unlock()
	listener.UpdateDefaultInterface("en0", 7, true, false)
	return nil
}

func (p *testApplePlatform) CloseDefaultInterfaceMonitor(listener InterfaceUpdateListener) error {
	p.access.Lock()
	defer p.access.Unlock()
	p.monitorCloses++
	if p.listener == listener {
		p.listener = nil
	}
	return nil
}

func (p *testApplePlatform) GetInterfaces() (NetworkInterfaceIterator, error) {
	p.access.Lock()
	p.interfaceReads++
	p.access.Unlock()
	return newIterator([]*NetworkInterface{{
		Name: "en0", Index: 7, MTU: 1500, Type: InterfaceTypeWIFI,
		Flags:     syscall.IFF_UP | syscall.IFF_RUNNING,
		Addresses: newIterator([]string{"192.0.2.2/24"}),
	}}), nil
}

func (p *testApplePlatform) UnderNetworkExtension() bool              { return p.underNE }
func (p *testApplePlatform) NetworkExtensionIncludeAllNetworks() bool { return p.includeAll }

func TestApplePlatformCapabilitiesAndFlags(t *testing.T) {
	if NewApplePlatform(nil) != nil {
		t.Fatal("nil Apple platform was not preserved")
	}
	for _, underNE := range []bool{false, true} {
		for _, includeAll := range []bool{false, true} {
			host := &testApplePlatform{underNE: underNE, includeAll: includeAll}
			platform := NewApplePlatform(host)
			wrapper := newPlatformInterfaceWrapper(platform)
			if got := wrapper.UnderNetworkExtension(); got != underNE {
				t.Fatalf("UnderNetworkExtension = %v, want %v", got, underNE)
			}
			if got := wrapper.NetworkExtensionIncludeAllNetworks(); got != (underNE && includeAll) {
				t.Fatalf("includeAll = %v for NE=%v, includeAll=%v", got, underNE, includeAll)
			}
			if wrapper.UsePlatformWIFIMonitor() || wrapper.UsePlatformConnectionOwnerFinder() || wrapper.UsePlatformNotification() {
				t.Fatal("Apple optional capabilities must be disabled")
			}
			if wrapper.UsePlatformAutoDetectInterfaceControl() || platform.UseProcFS() || platform.LocalDNSTransport() != nil {
				t.Fatal("Apple must not use Android socket, procfs, or DNS services")
			}
			if !wrapper.UsePlatformInterface() || !wrapper.UsePlatformDefaultInterfaceMonitor() || !wrapper.UsePlatformNetworkInterfaces() {
				t.Fatal("Apple tunnel/interface capabilities must remain enabled")
			}
			if err := platform.AutoDetectInterfaceControl(-1); err != nil {
				t.Fatalf("disabled protector: %v", err)
			}
			if platform.ReadWIFIState() != nil {
				t.Fatal("unsupported Wi-Fi state must be nil")
			}
			if _, err := platform.FindConnectionOwner(0, "", 0, "", 0); !errors.Is(err, os.ErrInvalid) {
				t.Fatalf("owner lookup = %v", err)
			}
		}
	}
}

func TestApplePlatformDelegation(t *testing.T) {
	sentinel := errors.New("host OpenTun error")
	host := &testApplePlatform{openErr: sentinel}
	platform := NewApplePlatform(host)
	options := &tunOptions{}
	fd, err := platform.OpenTun(options)
	if fd != 42 || !errors.Is(err, sentinel) || host.openOptions != options {
		t.Fatal("OpenTun did not preserve host arguments/result")
	}
	listener := &recordingInterfaceListener{}
	if err := platform.StartDefaultInterfaceMonitor(listener); err != nil {
		t.Fatal(err)
	}
	if !listener.updated || host.listener != listener {
		t.Fatal("monitor listener was not delegated")
	}
	interfaces, err := platform.GetInterfaces()
	if err != nil {
		t.Fatal(err)
	}
	if !interfaces.HasNext() || interfaces.Next().Name != "en0" {
		t.Fatal("GetInterfaces was not delegated")
	}
	if err := platform.CloseDefaultInterfaceMonitor(listener); err != nil {
		t.Fatal(err)
	}
	if host.listener != nil || host.monitorStarts != 1 || host.monitorCloses != 1 {
		t.Fatal("monitor close was not delegated")
	}
}

type recordingInterfaceListener struct{ updated bool }

func (l *recordingInterfaceListener) UpdateDefaultInterface(string, int32, bool, bool) {
	l.updated = true
}
func (l *recordingInterfaceListener) UpdateNetworkPath(string) {}

type testAndroidPlatform struct{ PlatformInterface }

func (*testAndroidPlatform) UseProcFS() bool                             { return true }
func (*testAndroidPlatform) UsePlatformAutoDetectInterfaceControl() bool { return true }

func TestAndroidPlatformCapabilitiesUnchanged(t *testing.T) {
	wrapper := newPlatformInterfaceWrapper(&testAndroidPlatform{})
	if !wrapper.UsePlatformWIFIMonitor() || !wrapper.UsePlatformConnectionOwnerFinder() || !wrapper.UsePlatformNotification() || !wrapper.UsePlatformAutoDetectInterfaceControl() || !wrapper.useProcFS {
		t.Fatal("Android default capabilities changed")
	}
	if wrapper.UnderNetworkExtension() || wrapper.NetworkExtensionIncludeAllNetworks() {
		t.Fatal("Android must not be a NetworkExtension")
	}
}

type forbiddenRawConn struct{ t *testing.T }

func (c forbiddenRawConn) Control(func(uintptr)) error {
	c.t.Fatal("Apple invoked Android socket protection")
	return nil
}
func (c forbiddenRawConn) Read(func(uintptr) bool) error  { return nil }
func (c forbiddenRawConn) Write(func(uintptr) bool) error { return nil }

func TestAppleDoesNotProtectSockets(t *testing.T) {
	previous := protector.Load()
	t.Cleanup(func() { protector.Store(previous) })
	platform := NewApplePlatform(&testApplePlatform{})
	installProtector(platform)
	defer releaseProtector(platform)
	if err := protectDial("tcp", "192.0.2.1:443", forbiddenRawConn{t}); err != nil {
		t.Fatal(err)
	}
}

func TestInterfaceSnapshotsAndNetworkCosts(t *testing.T) {
	wrapper := newPlatformInterfaceWrapper(NewApplePlatform(&testApplePlatform{}))
	wrapper.defaultInterface = &control.Interface{Name: "en0", Index: 7}
	wrapper.defaultInterfaceIndex = 7
	wrapper.isExpensive, wrapper.isConstrained = true, true
	wrapper.myTunAddress = []netip.Addr{netip.MustParseAddr("198.18.0.1")}
	snapshot := wrapper.MyInterfaceAddress()
	snapshot[0] = netip.MustParseAddr("198.18.0.2")
	if wrapper.MyInterfaceAddress()[0].String() != "198.18.0.1" {
		t.Fatal("MyInterfaceAddress exposed mutable backing slice")
	}
	monitor := &platformDefaultInterfaceMonitor{platformInterfaceWrapper: wrapper}
	monitor.RegisterMyInterface("utun42")
	names := monitor.MyInterfaces()
	names[0] = "modified"
	if monitor.MyInterfaces()[0] != "utun42" {
		t.Fatal("MyInterfaces exposed mutable backing slice")
	}
	interfaces, err := wrapper.NetworkInterfaces()
	if err != nil {
		t.Fatal(err)
	}
	if len(interfaces) != 1 || !interfaces[0].Expensive || !interfaces[0].Constrained {
		t.Fatalf("default interface costs: %+v", interfaces)
	}
	wrapper.myTunName = "en0"
	interfaces, err = wrapper.NetworkInterfaces()
	if err != nil {
		t.Fatal(err)
	}
	if interfaces[0].Expensive || interfaces[0].Constrained {
		t.Fatal("tunnel inherited underlying-network costs")
	}
}

type reentrantNetworkManager struct {
	adapter.NetworkManager
	wrapper *platformInterfaceWrapper
}

func (n *reentrantNetworkManager) UpdateInterfaces() error {
	_, err := n.wrapper.NetworkInterfaces()
	return err
}

func TestInterfaceUpdatesAllowReentrantNetworkRefresh(t *testing.T) {
	wrapper := newPlatformInterfaceWrapper(NewApplePlatform(&testApplePlatform{}))
	wrapper.networkManager = &reentrantNetworkManager{wrapper: wrapper}
	monitor := &platformDefaultInterfaceMonitor{platformInterfaceWrapper: wrapper, logger: log.StdLogger()}
	done := make(chan struct{})
	go func() {
		var workers sync.WaitGroup
		for worker := 0; worker < 3; worker++ {
			workers.Go(func() {
				for iteration := 0; iteration < 100; iteration++ {
					monitor.UpdateDefaultInterface("", -1, iteration%2 == 0, iteration%3 == 0)
					_, _ = wrapper.NetworkInterfaces()
					monitor.RegisterMyInterface("utun42")
					_ = monitor.MyInterfaces()
					_ = wrapper.MyInterfaceAddress()
				}
			})
		}
		workers.Wait()
		close(done)
	}()
	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("interface refresh deadlocked on reentrant NetworkInterfaces")
	}
}

type pathTestApplePlatform struct{ testApplePlatform }

func (*pathTestApplePlatform) GetInterfaces() (NetworkInterfaceIterator, error) {
	return newIterator([]*NetworkInterface{
		{Name: "en0", Index: 7, MTU: 1500, Type: InterfaceTypeWIFI},
		{Name: "pdp_ip0", Index: 8, MTU: 1500, Type: InterfaceTypeCellular},
		{Name: "utun42", Index: 9, MTU: 1500, Type: InterfaceTypeOther},
	}), nil
}

type pathTestInterfaceFinder struct{ control.InterfaceFinder }

func (*pathTestInterfaceFinder) ByIndex(index int) (*control.Interface, error) {
	return &control.Interface{Index: index, Name: map[int]string{7: "en0", 8: "pdp_ip0", 9: "utun42"}[index]}, nil
}

type pathTestNetworkManager struct {
	adapter.NetworkManager
	wrapper   *platformInterfaceWrapper
	snapshot  []adapter.NetworkInterface
	refreshes int
}

func (n *pathTestNetworkManager) UpdateInterfaces() error {
	n.refreshes++
	var err error
	n.snapshot, err = n.wrapper.NetworkInterfaces()
	return err
}

func (*pathTestNetworkManager) InterfaceFinder() control.InterfaceFinder {
	return &pathTestInterfaceFinder{}
}

func TestInterfacePathCostsApplyDuringFirstRefreshAndSwitch(t *testing.T) {
	wrapper := newPlatformInterfaceWrapper(NewApplePlatform(&pathTestApplePlatform{}))
	wrapper.myTunName = "utun42"
	network := &pathTestNetworkManager{wrapper: wrapper}
	wrapper.networkManager = network
	monitor := &platformDefaultInterfaceMonitor{platformInterfaceWrapper: wrapper, logger: log.StdLogger()}
	for _, test := range []struct {
		name                   string
		index                  int32
		expensive, constrained bool
	}{
		{"first path", 7, true, false},
		{"switch path", 8, false, true},
		{"tunnel excluded", 9, true, true},
		{"disconnect", -1, true, true},
	} {
		t.Run(test.name, func(t *testing.T) {
			before := network.refreshes
			monitor.UpdateDefaultInterface("", test.index, test.expensive, test.constrained)
			if network.refreshes != before+1 {
				t.Fatal("path update must refresh interfaces exactly once")
			}
			if len(network.snapshot) != 3 {
				t.Fatalf("interface snapshot: %+v", network.snapshot)
			}
			for _, networkInterface := range network.snapshot {
				isDefault := networkInterface.Index == int(test.index) && networkInterface.Name != "utun42"
				if networkInterface.Expensive != (isDefault && test.expensive) || networkInterface.Constrained != (isDefault && test.constrained) {
					t.Fatalf("stale path cost snapshot: interface=%+v path index=%d expensive=%v constrained=%v", networkInterface, test.index, test.expensive, test.constrained)
				}
			}
		})
	}
}
