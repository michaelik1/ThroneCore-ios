package mobile

import "testing"

const testCoreConfig = `{"log":{"disabled":true},"outbounds":[{"type":"direct","tag":"direct"}],"route":{"final":"direct"}}`
const testXrayConfig = `{"log":{"loglevel":"warning"},"outbounds":[{"protocol":"freedom","tag":"direct","settings":{}}]}`

func TestNewInstanceFailureReleasesProtector(t *testing.T) {
	previous := protector.Load()
	t.Cleanup(func() { protector.Store(previous) })
	for _, test := range []struct {
		name    string
		options StartOptions
	}{
		{"xray", StartOptions{CoreConfig: testCoreConfig, NeedXray: true, XrayConfig: "{invalid"}},
		{"config", StartOptions{CoreConfig: "{invalid", NeedXray: true, XrayConfig: testXrayConfig}},
		{"service", StartOptions{CoreConfig: `{"outbounds":[{"type":"direct","tag":"same"},{"type":"direct","tag":"same"}]}`}},
	} {
		t.Run(test.name, func(t *testing.T) {
			platform := NewApplePlatform(&testApplePlatform{})
			instance, err := NewInstance(platform, &test.options)
			if instance != nil {
				_ = instance.Close()
				t.Fatal("invalid construction succeeded")
			}
			if err == nil {
				t.Fatal("invalid construction returned no error")
			}
			if state := protector.Load(); state != nil && state.platform == platform {
				t.Fatal("failed construction retained its platform in protector state")
			}
		})
	}
}

func TestAppleInstanceStartCloseReconnect(t *testing.T) {
	previous := protector.Load()
	t.Cleanup(func() { protector.Store(previous) })
	if err := CheckConfig(testCoreConfig); err != nil {
		t.Fatal(err)
	}
	host := &testApplePlatform{}
	platform := NewApplePlatform(host)
	for cycle := 1; cycle <= 2; cycle++ {
		instance, err := NewInstance(platform, &StartOptions{CoreConfig: testCoreConfig, NeedXray: true, XrayConfig: testXrayConfig})
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() { _ = instance.Close() })
		if err := instance.Start(); err != nil {
			t.Fatal(err)
		}
		if err := instance.Start(); err == nil {
			t.Fatal("second start succeeded")
		}
		if err := instance.Close(); err != nil {
			t.Fatal(err)
		}
		if err := instance.Close(); err != nil {
			t.Fatal(err)
		}
		if err := instance.Start(); err == nil {
			t.Fatal("closed instance restarted")
		}
		if host.monitorStarts != cycle || host.monitorCloses != cycle || host.listener != nil || host.interfaceReads == 0 {
			t.Fatalf("monitor lifecycle after cycle %d: starts=%d closes=%d reads=%d", cycle, host.monitorStarts, host.monitorCloses, host.interfaceReads)
		}
		if state := protector.Load(); state != nil && state.platform == platform {
			t.Fatal("closed instance retained protector state")
		}
	}
}
