package MySQL;

BEGIN {
    no warnings 'redefine';

	sub LOG_READ_EOF () {-1;}
	sub LOG_READ_BOGUS () {-2;}
	sub LOG_READ_IO () {-3;}
	sub LOG_READ_MEM () {-5;}
	sub LOG_READ_TRUNC () {-6;}
	sub LOG_READ_TOO_LARGE () {-7;}
	sub LOG_EVENT_OFFSET () {4;}
	sub BINLOG_VERSION () {3;}
	sub ST_SERVER_VER_LEN () {50;}
	sub DUMPFILE_FLAG () {0x1;}
	sub OPT_ENCLOSED_FLAG () {0x2;}
	sub REPLACE_FLAG () {0x4;}
	sub IGNORE_FLAG () {0x8;}
	sub FIELD_TERM_EMPTY () {0x1;}
	sub ENCLOSED_EMPTY () {0x2;}
	sub LINE_TERM_EMPTY () {0x4;}
	sub LINE_START_EMPTY () {0x8;}
	sub ESCAPED_EMPTY () {0x10;}
	sub NUM_LOAD_DELIM_STRS () {5;}
	sub LOG_EVENT_HEADER_LEN () {19;}
	sub OLD_HEADER_LEN () {13;}
	sub QUERY_HEADER_LEN () {(4+ 4+ 1+ 2);}
	sub LOAD_HEADER_LEN () {(4+ 4+ 4+ 1+1+ 4);}
	sub START_HEADER_LEN () {(2+  &ST_SERVER_VER_LEN + 4);}
	sub ROTATE_HEADER_LEN () {8;}
	sub CREATE_FILE_HEADER_LEN () {4;}
	sub APPEND_BLOCK_HEADER_LEN () {4;}
	sub EXEC_LOAD_HEADER_LEN () {4;}
	sub DELETE_FILE_HEADER_LEN () {4;}
	sub EVENT_TYPE_OFFSET () {4;}
	sub SERVER_ID_OFFSET () {5;}
	sub EVENT_LEN_OFFSET () {9;}
	sub LOG_POS_OFFSET () {13;}
	sub FLAGS_OFFSET () {17;}
	sub ST_BINLOG_VER_OFFSET () {0;}
	sub ST_SERVER_VER_OFFSET () {2;}
	sub ST_CREATED_OFFSET () {( &ST_SERVER_VER_OFFSET +  &ST_SERVER_VER_LEN);}
	sub SL_MASTER_PORT_OFFSET () {8;}
	sub SL_MASTER_POS_OFFSET () {0;}
	sub SL_MASTER_HOST_OFFSET () {10;}
	sub Q_THREAD_ID_OFFSET () {0;}
	sub Q_EXEC_TIME_OFFSET () {4;}
	sub Q_DB_LEN_OFFSET () {8;}
	sub Q_ERR_CODE_OFFSET () {9;}
	sub Q_DATA_OFFSET () { &QUERY_HEADER_LEN;}
	sub I_TYPE_OFFSET () {0;}
	sub I_VAL_OFFSET () {1;}
	sub RAND_SEED1_OFFSET () {0;}
	sub RAND_SEED2_OFFSET () {8;}
	sub L_THREAD_ID_OFFSET () {0;}
	sub L_EXEC_TIME_OFFSET () {4;}
	sub L_SKIP_LINES_OFFSET () {8;}
	sub L_TBL_LEN_OFFSET () {12;}
	sub L_DB_LEN_OFFSET () {13;}
	sub L_NUM_FIELDS_OFFSET () {14;}
	sub L_SQL_EX_OFFSET () {18;}
	sub L_DATA_OFFSET () { &LOAD_HEADER_LEN;}
	sub R_POS_OFFSET () {0;}
	sub R_IDENT_OFFSET () {8;}
	sub CF_FILE_ID_OFFSET () {0;}
	sub CF_DATA_OFFSET () { &CREATE_FILE_HEADER_LEN;}
	sub AB_FILE_ID_OFFSET () {0;}
	sub AB_DATA_OFFSET () { &APPEND_BLOCK_HEADER_LEN;}
	sub EL_FILE_ID_OFFSET () {0;}
	sub DF_FILE_ID_OFFSET () {0;}
	sub QUERY_EVENT_OVERHEAD () {( &LOG_EVENT_HEADER_LEN+ &QUERY_HEADER_LEN);}
	sub QUERY_DATA_OFFSET () {( &LOG_EVENT_HEADER_LEN+ &QUERY_HEADER_LEN);}
	sub ROTATE_EVENT_OVERHEAD () {( &LOG_EVENT_HEADER_LEN+ &ROTATE_HEADER_LEN);}
	sub LOAD_EVENT_OVERHEAD () {( &LOG_EVENT_HEADER_LEN+ &LOAD_HEADER_LEN);}
	sub CREATE_FILE_EVENT_OVERHEAD () {( &LOG_EVENT_HEADER_LEN+ + &LOAD_HEADER_LEN+ &CREATE_FILE_HEADER_LEN);}
	sub DELETE_FILE_EVENT_OVERHEAD () {( &LOG_EVENT_HEADER_LEN+ &DELETE_FILE_HEADER_LEN);}
	sub EXEC_LOAD_EVENT_OVERHEAD () {( &LOG_EVENT_HEADER_LEN+ &EXEC_LOAD_HEADER_LEN);}
	sub APPEND_BLOCK_EVENT_OVERHEAD () {( &LOG_EVENT_HEADER_LEN+ &APPEND_BLOCK_HEADER_LEN);}
	sub BINLOG_MAGIC () {"\\xfe\\x62\\x69\\x6e";}
	sub LOG_EVENT_TIME_F () {0x1;}
	sub LOG_EVENT_FORCED_ROTATE_F () {0x2;}
	sub UNKNOWN_EVENT () { 0; }
	sub START_EVENT () { 1; }
	sub QUERY_EVENT () { 2; }
	sub STOP_EVENT () { 3; }
	sub ROTATE_EVENT () { 4; }
	sub INTVAR_EVENT () { 5; }
	sub LOAD_EVENT () { 6; }
	sub SLAVE_EVENT () { 7; }
	sub CREATE_FILE_EVENT () { 8; }
	sub APPEND_BLOCK_EVENT () { 9; }
	sub EXEC_LOAD_EVENT () { 10; }
	sub DELETE_FILE_EVENT () { 11; }
	sub NEW_LOAD_EVENT () { 12; }
	sub RAND_EVENT () { 13; }
	sub INVALID_INT_EVENT () { 0; }
	sub LAST_INSERT_ID_EVENT () { 1; }
	sub INSERT_ID_EVENT () { 2; }
}




1;

