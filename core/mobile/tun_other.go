//go:build !darwin

package mobile

import tun "github.com/sagernet/sing-tun"

func newTun(options tun.Options) (tun.Tun, error) {
	return tun.New(options)
}
