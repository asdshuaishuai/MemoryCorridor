// corridor-wedge: an embedded WasmEdge host for the host-free `wasipure`
// service module. Same CLI shape as `wasmedge run --dir .:<root> <wasm>
// [--mcp]`, so scripts/wasipure_e2e.py's WASMEDGE_BIN accepts it as a
// drop-in; the point of the embedding is the distribution form: one native
// binary + libwasmedge + the engine wasm = a MemoryCorridor service that
// carries its runtime (the user's "直接采用 WasmEdge" direction).
//
// Build: scripts/build_wedge_host.sh (needs WasmEdge >=0.18 headers+lib).
#include <wasmedge/wasmedge.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static char *dup_str(const char *s) {
  char *p = (char *)malloc(strlen(s) + 1);
  strcpy(p, s);
  return p;
}

int main(int argc, char **argv) {
  const char *root = NULL;
  const char *module = NULL;
  const char *wasi_args[2];
  uint32_t wasi_argc = 1; // argv[0] = module program name
  wasi_args[0] = "wasipure.wasm";
  for (int i = 1; i < argc; i++) {
    if (strcmp(argv[i], "--dir") == 0 && i + 1 < argc) {
      const char *d = argv[++i]; // ".:/host/dir" (WasmEdge syntax)
      const char *colon = strchr(d, ':');
      root = dup_str(colon ? colon + 1 : d);
    } else if (strcmp(argv[i], "--mcp") == 0) {
      wasi_args[wasi_argc++] = "--mcp";
    } else if (argv[i][0] != '-') {
      module = argv[i];
    }
  }
  if (!module) {
    fprintf(stderr, "usage: corridor-wedge run --dir .:<root> <wasipure.wasm> [--mcp]\n");
    return 2;
  }
  char rootbuf[4096];
  if (!root) {
    if (!getcwd(rootbuf, sizeof rootbuf)) {
      fprintf(stderr, "corridor-wedge: no cwd\n");
      return 2;
    }
    root = rootbuf;
  }
  char preopen[8192];
  snprintf(preopen, sizeof preopen, ".:%s", root);
  const char *preopens[1] = { preopen };

  WasmEdge_ConfigureContext *conf = WasmEdge_ConfigureCreate();
  WasmEdge_VMContext *vm = WasmEdge_VMCreate(conf, NULL);
  WasmEdge_ModuleInstanceContext *wasi = WasmEdge_ModuleInstanceCreateWASIWithFds(
      wasi_args, wasi_argc, NULL, 0, preopens, 1, 0, 1, 2);
  if (!wasi) {
    fprintf(stderr, "corridor-wedge: WASI env failed\n");
    return 2;
  }
  WasmEdge_Result reg = WasmEdge_VMRegisterModuleFromImport(vm, wasi);
  if (!WasmEdge_ResultOK(reg)) {
    fprintf(stderr, "corridor-wedge: register WASI failed code=%u\n",
            WasmEdge_ResultGetCode(reg));
    return 2;
  }
  WasmEdge_String start = WasmEdge_StringWrap("_start", 6);
  WasmEdge_Result res = WasmEdge_VMRunWasmFromFile(vm, module, start, NULL, 0,
                                                   NULL, 0);
  int rc = 0;
  if (!WasmEdge_ResultOK(res)) {
    // wasipure's line loop exits via proc_exit(0) at stdin EOF: wasmedge
    // surfaces that as a Terminate result, not a failure.
    if (WasmEdge_ResultGetCode(res) == WasmEdge_ErrCode_Success ||
        WasmEdge_ResultGetCode(res) == WasmEdge_ErrCode_Terminated) {
      rc = 0;
    } else {
      fprintf(stderr, "corridor-wedge: run failed code=%u cat=%u\n",
              WasmEdge_ResultGetCode(res),
              WasmEdge_ResultGetCategory(res));
      rc = 1;
    }
  }
  WasmEdge_VMDelete(vm);
  WasmEdge_ConfigureDelete(conf);
  return 0;
}
