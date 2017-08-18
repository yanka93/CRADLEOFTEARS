use strict;

package LJR::xmlrpc;

sub xmlrpc_call {
  my ($xmlrpc, $method, $request) = @_;
  my $res;
  
  if ($xmlrpc) {
    $res = $xmlrpc->call ($method, $request);
    
    if ($res && $res->fault) {
      $res->{"err_text"} = $method . ":  " . "XML-RPC Error [" . $res->faultcode . "]: " . $res->faultstring;
    }
    elsif (!$res) {
      $res->{"err_text"} = $method . ":  " . "Unknown XML-RPC Error.";
    }
   
    $res->{"result"} = $res->result;
  }
  else {
    $res->{"err_text"} = "Invalid xmlrpc object";
  }
  
  return $res;
}

return 1;
