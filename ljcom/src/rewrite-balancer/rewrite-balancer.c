/* -*- Mode: C; tab-width: 4; c-basic-offset: 4; indent-tabs-mode: nil -*- */
/*
 *  rewrite-balancer
 */

#include <sys/types.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/socket.h>
#include <sys/signal.h>
#include <sys/resource.h>
#include <sys/select.h>
#include <sys/poll.h>
#include <fcntl.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>
#include <errno.h>
#include <time.h>
#include <pwd.h>

/* constants */
#define BUFFER_UDP 2000
#define BUFFER_STDIN 20000

/* maximal no. of servers */
#define SERVERS_MAX 256

/* max timeout before discarding server info */
#define SERVER_TIMEOUT 20

/* who we setuid/setgid to */
#define SETUID_USER "nobody"

/* globals */
int udp_socket = 0;     /* socket which listens to udp stats broadcasts */
int port = 4446;        /* port to listen on */

char *fname = 0;        /* name of the config file */

#define MAX_UDP_PARSE  10

unsigned char udp_buffer[MAX_UDP_PARSE][BUFFER_UDP];
unsigned char stdin_buffer[BUFFER_STDIN];

typedef struct {
    struct in_addr addr;
    int free;
    int active;
    time_t heardfrom;
} server;

typedef struct {
    int numservers;     /* how many servers */
    int total_free;     /* how many free children in all servers */
    int check_servers;  /* check against a list of permissible servers */
    int codever;        /* if non-zero, incoming messages must match */
    server servers[SERVERS_MAX];
} sconfig;       /* server config structure */

sconfig *config; /* global server config */

/* 
 * Generally we use the global variable config to access the list
 * of servers and other current data. High-level functions don't hesitate
 * to access this global variable directly. However, lower-level functions
 * for manipulating server data accept an explicit pointer to sconfig,
 * so they can be used by read_config() for cleanly changing configs 
 * on-the-fly.
 */

int read_config(void);

int init_config(void) {
    config = (sconfig *)malloc(sizeof(sconfig));
    if (config == 0) return 0;
    config->numservers = 0;
    config->total_free = 0;
    config->check_servers = 0;
    config->codever = 0;
    return 1;
}

int server_cmp(const void *arg1, const void *arg2) {
    server *s1 = (server *)arg1;
    server *s2 = (server *)arg2;

    if (s1->addr.s_addr == s2->addr.s_addr) return 0;
    return (s1->addr.s_addr > s2->addr.s_addr ? 1 : -1);
}

server *find_server(sconfig *conf, struct in_addr addr) {
    int down = 0;
    int up = conf->numservers-1;

    while (down < up) {
        int middle = (down+up)/2;
        if (conf->servers[middle].addr.s_addr == addr.s_addr)
            return &(conf->servers[middle]);
        else {
            if (conf->servers[middle].addr.s_addr > addr.s_addr)
                up = (middle == up ? middle-1 : middle);
            else 
                down = ( middle == down ? middle+1: middle);
        }
    }
    if (conf->servers[down].addr.s_addr == addr.s_addr)
        return &(conf->servers[down]);

    if (conf->check_servers)
        return 0;

    if (conf->numservers >= SERVERS_MAX)
        return 0;

    down = conf->numservers++;
    conf->servers[down].addr = addr;
    conf->servers[down].active = conf->servers[down].free = 0;
    conf->servers[down].heardfrom = 0;

    qsort(conf->servers, conf->numservers, sizeof(server), server_cmp);
    return find_server(conf, addr); /* recursive! */
}

void clear_server (sconfig *conf, server *sp) {
    if (sp->free) {
        conf->total_free -= sp->free;
        if (conf->total_free < 0) conf->total_free =0;
    }
    sp->free = sp->active = sp->heardfrom = 0;
}

int get_server (sconfig *conf, struct in_addr *addr) {
    int choice, i, count;

    if (conf->total_free == 0) return 0;
    choice = (rand() % conf->total_free) + 1;

    count = 0;

    for (i=0; i<conf->numservers; i++) {
        count += conf->servers[i].free;
        if (count >= choice) {
            time_t now = time(0);
            if (conf->servers[i].heardfrom && 
                (now - conf->servers[i].heardfrom > SERVER_TIMEOUT)) {
                int j;

                clear_server(conf, &(conf->servers[i]));

                /* this should happen rarely, so better walk them
                   all now instead of potentially a very deep recursion */
                for (j=0; j<conf->numservers; j++) {
                    if (conf->servers[j].heardfrom &&
                       (now - conf->servers[j].heardfrom > SERVER_TIMEOUT))
                        clear_server(conf, &(conf->servers[j]));
                }
                 
                /* now recurse */
                return get_server(conf, addr);
            }
            conf->servers[i].free--;
            conf->total_free--;
            *addr = conf->servers[i].addr;
            return 1;
        }
    }
    return 0;
}

void parse_message (char *buffer, int blen, 
                    struct in_addr inaddr) {
    char name[80];
    int val, len;
    int res;
    int bcast_ver = 0;
    server *sp;
    sconfig *conf = config;
    int codever = 0;

    buffer[blen]='\0';

    /* should we reread config? */
    if (strncmp(buffer, "RELOAD CONFIG", 13) == 0) {
        read_config();
        return;
    }

    sp = find_server(conf, inaddr);
    if (sp==0) return;

    clear_server(conf, sp);

    while ((res = sscanf(buffer, " %[^=]=%u %n", name, &val, &len))!=-1) {
        buffer += len;
        if (!strcmp(name, "bcast_ver"))
            bcast_ver = val;
        if (!strcmp(name, "active"))
            sp->active = val;
        if (!strcmp(name, "free"))
            sp->free = val;
        if (!strcmp(name, "codever"))
            codever = val;
    }
    if (bcast_ver != 1) {
        clear_server(conf, sp);
        return;
    }
    if (codever && conf->codever && conf->codever != codever) {
        clear_server(conf, sp);
        return;
    }

    conf->total_free += sp->free;

    return;
}

void prepare_rfds(fd_set *prfds, int *n) {
    int max = 0;

    FD_ZERO(prfds);
    FD_SET(udp_socket, prfds); 
    if (udp_socket > max) max = udp_socket;
    FD_SET(0, prfds);
    *n = max + 1;
}

int handle_url(void) {
    struct in_addr srv;
    sconfig *conf = config;

    if (get_server(conf, &srv) == 0)
        return 0; 

    printf("%s\n", inet_ntoa(srv));
    fflush(stdout);
    return 1;
}

enum bufstate_t { EMPTY = 0, FILLING, FULL };

void loop (void) {
    struct sockaddr_in addr;
    int socklen;
    fd_set rfds;
    unsigned char *buf = stdin_buffer;
    enum bufstate_t bufstate = EMPTY;

    /* time in Unix seconds when we last checked config */
    long last_conf_check = 0;
    struct timeval tv;
    struct timezone tz;

    stdin_buffer[0] = '\0';
    
    while(1) {
        int n, res;

        if (bufstate == FULL && handle_url()) {
            buf = stdin_buffer;
            bufstate = EMPTY;
        }

        prepare_rfds(&rfds, &n);
        tv.tv_sec = 3; tv.tv_usec = 0;
        res = select(n, &rfds, 0, 0, &tv);
        
        /* check if need to reread config */
        if (gettimeofday(&tv, &tz)==0) {
            if (tv.tv_sec - last_conf_check >3) {
                last_conf_check = tv.tv_sec;
                read_config();
            }
        }

        if (res) {
            if (FD_ISSET(0, &rfds)) {
                int len, size;
                unsigned char *newline;

                /* If we had a full buffer and got more, assume a child was killed
                   or something, and mod_rewrite isn't obeying its usual locking
                   behavior.  */
                if (bufstate == FULL) {
                    buf = stdin_buffer;
                    bufstate = EMPTY;
                }

                size = BUFFER_STDIN-1 - (buf - stdin_buffer);

                while (size && ((len = read(0, buf, size)) > 0)) {
                    buf+=len;
                    size-=len;
                }
                *buf = '\0';

                if (newline = strchr(stdin_buffer, '\n')) {
                    bufstate = FULL;
                    *newline = '\0';
                } else {
                    bufstate = FILLING;
                }
            }
            if (FD_ISSET(udp_socket, &rfds)) { 
                int pos = 0;     /* position in ring buffer */
                int ct = 0;      /* total items we read from network */
                int to_parse;    /* MIN(10, ct) */
                int i;

                /* ring buffer areas: */
                struct sockaddr_in addrs[MAX_UDP_PARSE];
                int lens[MAX_UDP_PARSE];
                
                /* load everything into our ring buffer first, then 
                 * parse things later. */
                socklen = sizeof(addr);
                while((lens[pos] = recvfrom(udp_socket, udp_buffer[pos], 
                                            BUFFER_UDP-1, 0, 
                                            (struct sockaddr *) &addrs[pos], 
                                            &socklen)) > 0) {
                    ct++;
                    if (++pos == MAX_UDP_PARSE)
                        pos = 0;
                }
                
                /* process last MAX_UDP_PARSE messages */
                to_parse = (ct > MAX_UDP_PARSE) ? MAX_UDP_PARSE : ct;
                pos = (pos + MAX_UDP_PARSE - to_parse) % MAX_UDP_PARSE;

                for (i=0; i<to_parse; i++) {
                    parse_message(udp_buffer[pos], lens[pos], addrs[pos].sin_addr);
                    if (++pos == MAX_UDP_PARSE) pos = 0;
                }

            }
        }
    }
}

server *add_server(sconfig *conf, char *name) {
    struct in_addr addr;
    if (inet_aton(name, &addr)==0) return 0;
    return find_server(conf, addr);
}

static time_t last_config = 0;

int read_config(void) {
    FILE *f;
    struct stat buf;
    sconfig *new_conf;
    int check_old;
    server *snew, *sold;
    int failed = 0;

    if (stat(fname, &buf) != 0)
        return 0;

    if (buf.st_mtime <= last_config)
        return 1;
    
    f = fopen(fname, "r");
    if (f == 0) {
        return 0;
    }

    /* printf("rereading config\n"); */

    /* make a new config and populate it */
    new_conf = (sconfig *)malloc(sizeof(sconfig));
    if (new_conf ==0) return 0;
    new_conf->numservers = new_conf->total_free = 0;
    new_conf->codever = 0;

    new_conf->check_servers = 0; /* for now, to allow adding */
    
    check_old = config->check_servers;
    config->check_servers = 1;   /* disallow adding temporarily */

    /* read servers into the new config, copying their children 
       information from the old one if available */

    while (!feof(f)) {
        char name[80];
        int len;
        char optname[80];
        int res;
        unsigned int val;
        
        if (fgets(name, 80, f) == 0) {
            if (feof(f))
                break;
            /* error, retain old config */
            failed = 1;
            break;
        }

        if ((res = sscanf(name, " %[^=]=%u ", optname, &val))==2) {
            if (!strcmp(optname, "codever")) {
                new_conf->codever=val;
                continue;
            }
            else { /* unknown config option */
                failed = 1;
                break;
            }
        }
        len = strlen(name);
        if (len && name[len-1]=='\n')
            name[len-1]='\0';
        snew = add_server(new_conf, name);
        if (snew) {
            sold = add_server(config, name);
            if (sold) {
                /* copy activity info from the old config */
                snew->free = sold->free;
                snew->active = sold->active;
                snew->heardfrom = sold->heardfrom;
                new_conf->total_free += snew->free;
            }
        }
    }

    fclose(f);

    if (failed) {
        config->check_servers = check_old;
        free(new_conf);
        return 0;
    }

    /* success, replace old config with new */
    free(config);
    config = new_conf;
    config->check_servers = 1;

    last_config = buf.st_mtime;
    return 1;
}
        
int main (int argc, char **argv) {
    struct sockaddr_in addr;
    char c;

    if (init_config() == 0) {
        printf("couldn't initialize server config\n");
        exit(1);
    }

    while ((c = getopt(argc, argv, "p:f:")) != -1) {
        switch (c) {
        case 'p':
            port = atoi(optarg);
            break;
        case 'f':
            if ((fname = malloc(strlen(optarg)+1))==0) {
                printf("couldn't allocate space for file name\n");
                exit(1);
            }
            strcpy(fname, optarg);
            if (read_config() == 0) {
                printf("error reading the config file");
                exit(1);
            }
            break;
        default:
            fprintf(stderr, "Illegal argument \"%c\"\n", c);
            return 1;
        }
    }

    /* create and bind the udp socket */

    udp_socket = socket(PF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (udp_socket == -1) {
        printf("couldn't create the UDP socket\n");
        exit(1);
    }

    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = INADDR_ANY;
    addr.sin_port = htons(port);

    if (bind(udp_socket, (struct sockaddr *)&addr, sizeof(addr)) == -1) {
        printf("couldn't bind the UDP socket\n");
        exit(1);
    }

    /* make stdin line-buffered and stdout unbuffered */
    setlinebuf(stdin);
    setbuf(stdout, 0);

    /* enable nonblocking behavior */
    fcntl(0, F_SETFL, O_NONBLOCK);
    fcntl(udp_socket, F_SETFL, O_NONBLOCK);

    /* lose root privileges if we have them */
    if (getuid()== 0 || geteuid()==0) {
        struct passwd *pw;

        if ((pw = getpwnam(SETUID_USER)) == 0) {
            fprintf(stderr, "can't find the user %s to switch to\n", SETUID_USER);
            return 1;
        }
        if (setgid(pw->pw_gid)<0 || setuid(pw->pw_uid)<0) {
            fprintf(stderr, "failed to assume identity of user %s\n", SETUID_USER);
            return 1;
        }
    }

    /* enter the loop */
    loop();

    return 0;
}

