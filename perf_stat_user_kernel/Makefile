CXX      = g++
CXXFLAGS = -std=c++17 -O2 -Wall -Wextra -fPIC
INC      = -I./include

# ---- Percorso PAPI (via Spack) -----------------------------------------------
# Carica automaticamente da `spack location -i papi` se disponibile.
# Puoi sovrascriverlo: make PAPI_PREFIX=/tuo/percorso
PAPI_PREFIX ?= $(shell bash -c '\
    source /home/olly/spack/share/spack/setup-env.sh 2>/dev/null && \
    spack env activate mudock_zen5 2>/dev/null && \
    spack load papi 2>/dev/null && \
    spack location -i papi 2>/dev/null')

PAPI_INC = $(if $(PAPI_PREFIX),-I$(PAPI_PREFIX)/include,)
PAPI_LIB = $(if $(PAPI_PREFIX),-L$(PAPI_PREFIX)/lib -Wl$(comma)-rpath$(comma)$(PAPI_PREFIX)/lib -lpapi,)
comma    = ,

# ---- Target ------------------------------------------------------------------
LIB_USER  = libaca_user_events.a
LIB_PAPI  = libaca_papi_tracer.a

SRCS_USER = src/aca_user_events.cpp
SRCS_PAPI = src/aca_papi_tracer.cpp
OBJS_USER = $(SRCS_USER:.cpp=.o)
OBJS_PAPI = $(SRCS_PAPI:.cpp=.o)

.PHONY: all user papi example_user example_papi clean check_papi

# Default: compila solo la libreria user events (non dipende da PAPI)
all: user
	@echo ""
	@echo "Build completato:"
	@echo "  $(LIB_USER)  — linka con: -DACA_ENABLE_USER_EVENTS -laca_user_events"
	@echo ""
	@echo "Per la libreria PAPI:"
	@echo "  make papi   (richiede ambiente Spack mudock_zen5)"

# Libreria User Events (senza dipendenze esterne)
user: $(LIB_USER)

$(LIB_USER): $(OBJS_USER)
	ar rcs $@ $^
	@echo "[OK] $(LIB_USER) creata."

src/aca_user_events.o: src/aca_user_events.cpp include/aca_user_events.hpp
	$(CXX) $(CXXFLAGS) $(INC) -DACA_ENABLE_USER_EVENTS -c $< -o $@

# Libreria PAPI (richiede PAPI installato)
papi: check_papi $(LIB_PAPI)
	@echo "[OK] $(LIB_PAPI) creata."
	@echo "     Linka con: -DACA_ENABLE_PAPI $(PAPI_INC) $(PAPI_LIB)"

check_papi:
	@if [ -z "$(PAPI_PREFIX)" ]; then \
		echo "[ERR] PAPI non trovato. Esegui:"; \
		echo "       source /home/olly/spack/share/spack/setup-env.sh"; \
		echo "       spack env activate mudock_zen5 && spack load papi"; \
		echo "      oppure: make PAPI_PREFIX=/tuo/percorso papi"; \
		exit 1; \
	fi
	@echo "[OK] PAPI trovato: $(PAPI_PREFIX)"

$(LIB_PAPI): $(OBJS_PAPI)
	ar rcs $@ $^

src/aca_papi_tracer.o: src/aca_papi_tracer.cpp include/aca_papi_tracer.hpp
	$(CXX) $(CXXFLAGS) $(INC) $(PAPI_INC) -DACA_ENABLE_PAPI -c $< -o $@

# Esempio standalone User Events
example_user: $(LIB_USER) templates/example_usage.cpp
	$(CXX) $(CXXFLAGS) $(INC) -DACA_ENABLE_USER_EVENTS \
		templates/example_usage.cpp -L. -laca_user_events \
		-o example_usage
	@echo "[OK] Compilato: example_usage"
	@echo "     Esegui: ACA_USER_EVENT_1_NAME=Test ACA_TRACE_USER_OUT=traces/test.json ./example_usage"

# Esempio standalone PAPI (richiede PAPI)
example_papi: papi templates/example_papi.cpp
	$(CXX) $(CXXFLAGS) $(INC) $(PAPI_INC) -DACA_ENABLE_PAPI \
		templates/example_papi.cpp -L. -laca_papi_tracer \
		$(PAPI_LIB) -lpthread \
		-o example_papi
	@echo "[OK] Compilato: example_papi"
	@echo "     Prerequisito: sudo sysctl -w kernel.perf_event_paranoid=-1"
	@echo "     Esegui: ACA_PAPI_KNL_1_NAME=MyKernel ACA_PAPI_REPORT_OUT=traces/kpi.txt ./example_papi"

clean:
	rm -f $(OBJS_USER) $(OBJS_PAPI) $(LIB_USER) $(LIB_PAPI) \
	      example_usage example_papi
