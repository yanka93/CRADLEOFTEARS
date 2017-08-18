/*
 * mod_latency.c --
 *
 */

#include "httpd.h"
#include "http_config.h"
#include "http_request.h"
#include "http_core.h"
#include "http_protocol.h"
#include "http_main.h"

#include <time.h>

module MODULE_VAR_EXPORT latency_module;

typedef struct lcfg {
  int timeset;  /* This is basically pointless, but in the future
                 * it could be used to see if the default values
                 * being used or not.
                 */ 
  struct timespec latency_val;
} lcfg;

const char *latency_set(cmd_parms *cmd, void *mconfig, const char *arg)
{
  lcfg *cfg = (lcfg *) mconfig;

  cfg->timeset = 1;
  cfg->latency_val.tv_nsec = atoi(arg) * 1e6 - 1;
  return NULL;
}

static int do_pause (request_rec *r)
{
  lcfg *cfg;

  cfg = ap_get_module_config(r->per_dir_config, &latency_module);
  nanosleep(&cfg->latency_val, NULL);
  return OK;
}

/* Note the ACCESS_CONF bit there. That means the directive can be
 * set anywhere inside a <Directory> or <Location> thing. If this
 * is too restricting, I suggest changing it to "OR_OPTIONS"
 * That allows you to set it anywhere, and in .htaccess files where
 * AllowOverride Options is set in the directory.
 */
command_rec latency_cmds[] = {
  { "SetLatency",      latency_set, NULL, ACCESS_CONF, TAKE1, NULL },
  { NULL }
};

/* Directory based values. I won't write merge functions, since there is
 * only one value to care about. It defaults to the nearest one.
 */
static void *latency_create_dir_config(pool *p, char *dirspec)
{
  lcfg *cfg;
  /* Allocate memory out of the supplied pool. */
  cfg = (lcfg *) ap_pcalloc(p, sizeof(lcfg));
  /* Set default values. */
  cfg->timeset = 1;
  cfg->latency_val.tv_sec = 0;
  cfg->latency_val.tv_nsec = 350 * 1e6;
  /* All done. Return it. */
  return (void *) cfg;
}

module MODULE_VAR_EXPORT latency_module = {
  STANDARD_MODULE_STUFF,
  NULL,         /* initializer */
  latency_create_dir_config,         /* per-dir config creator */
  NULL,         /* per-dir config merger (default: override) */
  NULL,         /* per-server config creator */
  NULL,         /* per-server config merger (default: override) */
  latency_cmds, /* command table */
  NULL,         /* [9] content handlers */
  NULL,         /* [2] URI-to-filename translation */
  NULL,         /* [5] authenticate user_id */
  NULL,         /* [6] authorize user_id */
  NULL,         /* [4] check access (based on src & http headers) */
  NULL,         /* [7] check/set MIME type */
  NULL,         /* [8] fixups */
  NULL,         /* [10] logger */
  do_pause,     /* [3] header-parser */
  NULL,         /* process initialization */
  NULL,         /* process exit/cleanup */
  NULL          /* [1] post read-request handling */
};
