package mobile

import (
	"fmt"
	"net"

	"golang.org/x/sys/unix"
)

func getTunnelName(fd int32) (string, error) {
	const (
		sysProtoControl = 2 // SYSPROTO_CONTROL
		utunOptIfName   = 2 // UTUN_OPT_IFNAME
	)
	name, err := unix.GetsockoptString(int(fd), sysProtoControl, utunOptIfName)
	if err != nil {
		return "", fmt.Errorf("failed to get name of utun device: %w", err)
	}
	return name, nil
}

func dup(fd int) (int, error) {
	// sing-tun treats 0 as create-new; also avoid reusing closed standard streams.
	return unix.FcntlInt(uintptr(fd), unix.F_DUPFD_CLOEXEC, 3)
}

// copied from net.linkFlags
func linkFlags(rawFlags uint32) net.Flags {
	var flags net.Flags
	if rawFlags&unix.IFF_UP != 0 {
		flags |= net.FlagUp
	}
	if rawFlags&unix.IFF_RUNNING != 0 {
		flags |= net.FlagRunning
	}
	if rawFlags&unix.IFF_BROADCAST != 0 {
		flags |= net.FlagBroadcast
	}
	if rawFlags&unix.IFF_LOOPBACK != 0 {
		flags |= net.FlagLoopback
	}
	if rawFlags&unix.IFF_POINTOPOINT != 0 {
		flags |= net.FlagPointToPoint
	}
	if rawFlags&unix.IFF_MULTICAST != 0 {
		flags |= net.FlagMulticast
	}
	return flags
}
