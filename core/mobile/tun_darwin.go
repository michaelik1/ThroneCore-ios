package mobile

import (
	"os"

	tun "github.com/sagernet/sing-tun"
	"golang.org/x/sys/unix"
)

// newTun takes ownership only of the duplicate in FileDescriptor, never the host's descriptor.
func newTun(options tun.Options) (tun.Tun, error) {
	if options.FileDescriptor <= 0 {
		return nil, os.ErrInvalid
	}
	// NetworkExtension owns addresses/routes/DNS. sing-tun must not configure them or undo them
	// on Close. This also avoids invoking desktop DNS-cache tools from the extension.
	options.EXP_ExternalConfiguration = true
	device, err := tun.New(options)
	if err != nil {
		// The pinned sing-tun does not close a supplied FD when configure fails. After success,
		// NativeTun.Close owns it instead.
		_ = unix.Close(options.FileDescriptor)
	}
	return device, err
}

// GetTunnelFileDescriptor discovers a borrowed utun descriptor in the current process, or -1
// if none is found among descriptors 0..1023. It follows the upstream libbox compatibility path;
// it is not a supported public NEPacketTunnelFlow API. Call only after the provider's tunnel
// settings have been applied, with one active packet tunnel in the process. The caller must not
// close the returned descriptor. OpenInterface duplicates it before handing it to sing-tun.
func GetTunnelFileDescriptor() int32 {
	ctlInfo := &unix.CtlInfo{}
	copy(ctlInfo.Name[:], "com.apple.net.utun_control")
	for fd := range 1024 {
		address, err := unix.Getpeername(fd)
		if err != nil {
			continue
		}
		controlAddress, ok := address.(*unix.SockaddrCtl)
		if !ok {
			continue
		}
		if ctlInfo.Id == 0 {
			if err := unix.IoctlCtlInfo(fd, ctlInfo); err != nil {
				continue
			}
		}
		if controlAddress.ID == ctlInfo.Id {
			return int32(fd)
		}
	}
	return -1
}
