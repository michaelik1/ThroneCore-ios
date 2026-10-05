package mobile

import (
	"errors"
	"os"
	"strings"
	"testing"

	tun "github.com/sagernet/sing-tun"
	"golang.org/x/sys/unix"
)

func TestDarwinDuplicateBorrowedDescriptor(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	borrowed := int(reader.Fd())
	owned, err := dup(borrowed)
	if err != nil {
		t.Fatal(err)
	}
	if owned < 3 || owned == borrowed {
		t.Fatalf("duplicate = %d, borrowed = %d", owned, borrowed)
	}
	flags, err := unix.FcntlInt(uintptr(owned), unix.F_GETFD, 0)
	if err != nil {
		t.Fatal(err)
	}
	if flags&unix.FD_CLOEXEC == 0 {
		t.Fatal("duplicate is missing CLOEXEC")
	}
	if err := unix.Close(owned); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.FcntlInt(uintptr(borrowed), unix.F_GETFD, 0); err != nil {
		t.Fatalf("closing duplicate closed borrowed FD: %v", err)
	}
	if _, err := dup(-1); !errors.Is(err, unix.EBADF) {
		t.Fatalf("dup invalid FD: %v", err)
	}
}

func TestDarwinNewTunFailureClosesOnlyDuplicate(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	defer reader.Close()
	defer writer.Close()
	borrowed := int(reader.Fd())
	owned, err := dup(borrowed)
	if err != nil {
		t.Fatal(err)
	}
	device, err := newTun(tun.Options{FileDescriptor: owned, MTU: 1500, EXP_MultiPendingPackets: true})
	if device != nil {
		_ = device.Close()
		t.Fatal("pipe accepted as utun")
	}
	if err == nil || !strings.Contains(err.Error(), "UTUN_OPT_MAX_PENDING_PACKETS") {
		t.Fatalf("expected utun configuration failure, got %v", err)
	}
	if _, err := unix.FcntlInt(uintptr(owned), unix.F_GETFD, 0); !errors.Is(err, unix.EBADF) {
		t.Fatalf("failed TUN retained duplicate: %v", err)
	}
	if _, err := unix.FcntlInt(uintptr(borrowed), unix.F_GETFD, 0); err != nil {
		t.Fatalf("failed TUN closed borrowed FD: %v", err)
	}
}

func TestDarwinInvalidTunnelDescriptors(t *testing.T) {
	if _, err := getTunnelName(-1); !errors.Is(err, unix.EBADF) {
		t.Fatalf("invalid tunnel name query: %v", err)
	}
	for _, fd := range []int{-1, 0} {
		if _, err := newTun(tun.Options{FileDescriptor: fd, MTU: 1500}); !errors.Is(err, os.ErrInvalid) {
			t.Fatalf("newTun(%d): %v", fd, err)
		}
	}
}

func TestDarwinNewTunExternalConfigurationOwnsOnlyDuplicate(t *testing.T) {
	// With batching disabled, sing-tun can wrap a socket pair without configuring utun options.
	// A nil InterfaceMonitor makes Start fail if external configuration is not enabled.
	descriptors, err := unix.Socketpair(unix.AF_UNIX, unix.SOCK_DGRAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer unix.Close(descriptors[0])
	defer unix.Close(descriptors[1])
	owned, err := dup(descriptors[0])
	if err != nil {
		t.Fatal(err)
	}
	device, err := newTun(tun.Options{FileDescriptor: owned, MTU: 1500})
	if err != nil {
		t.Fatal(err)
	}
	if err := device.Start(); err != nil {
		_ = device.Close()
		t.Fatal(err)
	}
	if err := device.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := unix.FcntlInt(uintptr(owned), unix.F_GETFD, 0); !errors.Is(err, unix.EBADF) {
		t.Fatalf("closed TUN retained its duplicate: %v", err)
	}
	if _, err := unix.FcntlInt(uintptr(descriptors[0]), unix.F_GETFD, 0); err != nil {
		t.Fatalf("closed TUN closed borrowed FD: %v", err)
	}
}
