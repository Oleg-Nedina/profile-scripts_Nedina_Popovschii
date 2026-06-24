CXX      = g++
CXXFLAGS = -std=c++17 -O2 -fPIC -Wall -Wextra
LDFLAGS  = -shared -ldl -lpthread

OMPT_INC = -I.

TARGETS  = libhigh_level.so libperfetto_preload.so libompt_tracer.so

.PHONY: all clean

all: $(TARGETS)

libhigh_level.so: high_level_so.cpp
	$(CXX) $(CXXFLAGS) $(LDFLAGS) -o $@ $<
	@echo "[OK] Compilato: $@"

libperfetto_preload.so: perfetto_preload.cpp perfetto_sdk/perfetto.cc
	$(CXX) $(CXXFLAGS) -I. $(LDFLAGS) -o $@ $^
	@echo "[OK] Compilato: $@"
	@echo "     Usa con:  LD_PRELOAD=./$@ MUDOCK_TRACE_PERFETTO_OUT=traces/muDock.pftrace ./build/application/muDock ..."

libompt_tracer.so: ompt_tracer.cpp
	$(CXX) $(CXXFLAGS) $(OMPT_INC) $(LDFLAGS) -o $@ $<
	@echo "[OK] Compilato: $@"

clean:
	rm -f $(TARGETS)

