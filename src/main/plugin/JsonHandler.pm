# Copyright (c) 2013, ickStream GmbH
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions are met:
#     * Redistributions of source code must retain the above copyright
#       notice, this list of conditions and the following disclaimer.
#     * Redistributions in binary form must reproduce the above copyright
#       notice, this list of conditions and the following disclaimer in the
#       documentation and/or other materials provided with the distribution.
#     * Neither the name of ickStream nor the
#       names of its contributors may be used to endorse or promote products
#       derived from this software without specific prior written permission.
# 
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
# WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
# DISCLAIMED. IN NO EVENT SHALL LOGITECH, INC BE LIABLE FOR ANY
# DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
# (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
# LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
# ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
# (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
# SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

package Plugins::IckStreamPlugin::JsonHandler;

use strict;
use warnings;

use base qw(Slim::Plugin::Base);

use File::Spec::Functions;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Web::JSONRPC;

use HTTP::Status qw(RC_OK);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);
use Slim::Web::HTTP;
use HTTP::Status qw(RC_MOVED_TEMPORARILY RC_NOT_FOUND);
use Slim::Utils::Compress;
use POSIX qw(floor);
use Crypt::Tea;

my $log = logger('plugin.ickstream');
my $prefs  = preferences('plugin.ickstream');


# this holds a context for each connection, to enable asynchronous commands as well
# as subscriptions.
our %contexts = ();

# handleClose
# deletes any internal references to the $httpClient
sub handleClose {
        my $httpClient = shift || return;

        if (defined $contexts{$httpClient}) {
                main::DEBUGLOG && $log->debug("Closing any subscriptions for $httpClient");
        
                # remove any subscription management
                Slim::Control::Request::unregisterAutoExecute($httpClient);
                
                # delete the context
                delete $contexts{$httpClient};
        }
}

# genreateJSONResponse

sub generateJSONResponse {
        my $context = shift;
        my $result = shift;
        my $error = shift;

        if($log->is_debug) { $log->debug("generateJSONResponse()"); }

        # create an object for the response
        my $response = {};
        $response->{'jsonrpc'} = defined($context->{'procedure'}->{'jsonrpc'}) ? $context->{'procedure'}->{'jsonrpc'} : "2.0";
        
        # add ID if we have it
        if (defined(my $id = $context->{'procedure'}->{'id'})) {
                $response->{'id'} = $id;
        }
        # add result
        $response->{'result'} = $result if(defined($result));
        $response->{'error'} = $error if (defined($error) && !defined($result));

        Slim::Web::JSONRPC::writeResponse($context, $response);
}


# requestWrite( $request $httpClient, $context)
# Writes a request downstream. $httpClient and $context are retrieved if not
# provided (from the request->connectionID and from the contexts array, respectively)
sub requestWrite {
        my $result = shift;
        my $httpClient = shift;
        my $context = shift;
        my $error = shift;

        if($log->is_debug) { $log->debug("requestWrite()"); }
        if($log->is_debug) { $log->debug(Data::Dump::dump($result)); }
        if($log->is_debug) { $log->debug(Data::Dump::dump($error)); }

        if (!$httpClient) {
                
                # recover our http client
                #$httpClient = $request->connectionID();
        }
        
        if (!$context) {
        
                # recover our beloved context
                $context = $contexts{$httpClient};
                
                if (!$context) {
                        $log->error("Context not found in requestWrite!!!!");
                        return;
                }
        } else {

                if (!$httpClient) {
                        $log->error("httpClient not found in requestWrite!!!!");
                        return;
                }
        }

        # this should never happen, we've normally been forwarned by the closeHandler
        if (!$httpClient->connected()) {
                main::INFOLOG && $log->info("Client no longer connected in requestWrite");
                handleClose($httpClient);
                return;
        }
        generateJSONResponse($context, $result, $error);
}

sub getContext {
	my $httpClient = shift;
	
	if(defined($contexts{$httpClient})) {
		return $contexts{$httpClient};
	}
	return undef;
}

sub setContext {
	my $httpClient = shift;
	my $context = shift;

	$contexts{$httpClient} = $context;	
}


1;
