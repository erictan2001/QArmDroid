/* patch-wrapper.c: shim so meson's `patch --version` check (>=2.6.1) passes,
 * forwarding real work to busybox64's `patch` applet. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <process.h>

int main(int argc, char **argv) {
    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--version") == 0) {
            printf("patch 2.7.6-acme\n");
            return 0;
        }
    }
    /* Forward to busybox, whose multi-call binary dispatches on argv[0]. */
    const char *bb = "C:\\Users\\erict\\OneDrive\\Desktop\\Arm64AndroidEmulator\\tools\\qemu-gfxstream\\tools\\busybox64.exe";
    char **nargv = (char **)malloc((argc + 1) * sizeof(char *));
    nargv[0] = (char *)"patch";
    for (int i = 1; i < argc; i++) nargv[i] = argv[i];
    nargv[argc] = NULL;
    intptr_t rc = _spawnvp(_P_WAIT, bb, (const char *const *)nargv);
    free(nargv);
    return (int)rc;
}
