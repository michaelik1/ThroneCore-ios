package mobile

import "os"

// ApplePlatformInterface is the host contract for Apple platforms. NetworkExtension hosts apply
// network settings in OpenTun before returning a borrowed utun descriptor. The host retains
// ownership of that descriptor; the core duplicates it for its own lifetime.
//
// Optional Android services (socket protection, package/owner lookup, platform DNS, Wi-Fi state
// and notifications) are deliberately absent. Use NewApplePlatform to adapt this to NewInstance.
type ApplePlatformInterface interface {
	OpenTun(options TunOptions) (int32, error)
	StartDefaultInterfaceMonitor(listener InterfaceUpdateListener) error
	CloseDefaultInterfaceMonitor(listener InterfaceUpdateListener) error
	GetInterfaces() (NetworkInterfaceIterator, error)
	UnderNetworkExtension() bool
	NetworkExtensionIncludeAllNetworks() bool
}

// NewApplePlatform adapts an Apple host to the existing mobile runtime without changing the
// Android PlatformInterface contract. A nil host yields nil and is rejected by NewInstance.
func NewApplePlatform(platform ApplePlatformInterface) PlatformInterface {
	if platform == nil {
		return nil
	}
	return &applePlatform{platform}
}

var _ PlatformInterface = (*applePlatform)(nil)

type applePlatform struct {
	ApplePlatformInterface
}

func (p *applePlatform) LocalDNSTransport() LocalDNSTransport        { return nil }
func (p *applePlatform) UsePlatformAutoDetectInterfaceControl() bool { return false }
func (p *applePlatform) AutoDetectInterfaceControl(fd int32) error   { return nil }
func (p *applePlatform) UseProcFS() bool                             { return false }

func (p *applePlatform) FindConnectionOwner(ipProtocol int32, sourceAddress string, sourcePort int32, destinationAddress string, destinationPort int32) (*ConnectionOwner, error) {
	return nil, os.ErrInvalid
}

func (p *applePlatform) PackageNamesByUid(uid int32) (StringIterator, error) {
	return nil, os.ErrInvalid
}

func (p *applePlatform) ReadWIFIState() *WIFIState                         { return nil }
func (p *applePlatform) ClearDNSCache()                                    {}
func (p *applePlatform) SendNotification(notification *Notification) error { return os.ErrInvalid }
func (p *applePlatform) CancelNotification(identifier string, typeID int32) error {
	return os.ErrInvalid
}
