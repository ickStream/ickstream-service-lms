# Copyright (c) 2014, ickStream GmbH
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

package Plugins::IckStreamPlugin::LocalServiceManager;

use strict;
use Scalar::Util qw(blessed);
use Plugins::IckStreamPlugin::Plugin;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.ickstream');
my $prefs = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');
my $KEY = undef;

my $localRequestedServices = {};
my $localServiceRequestIds = {};
my $localServices = {};

sub init {
	my $plugin = shift;
	$KEY = Slim::Utils::PluginManager->dataForPlugin($plugin)->{'id'};
}

sub _setService {
	my $serviceId = shift;
	my $serviceInformation = shift;
	
	$localServices->{$serviceId} = $serviceInformation->{'serviceUrl'};
	$log->info("Got url for service(".$serviceInformation->{'name'}."): ".$localServices->{$serviceId});
}

sub _serviceExists {
	my $serviceId = shift;
	return defined($localServices->{$serviceId});
}

sub removeService {
	my $serviceId = shift;
	
	if(_serviceExists($serviceId)) {
		$localServices->{$serviceId} = undef;
		my $requestId = $localRequestedServices->{$serviceId};
		$localRequestedServices->{$serviceId} = undef;
		if(defined($requestId)) {
			$localServiceRequestIds->{$requestId} = undef;
		}
	}
}

sub resolveServiceUrl {
	my $serviceId = shift;
	my $serviceUrl = shift;

	if($serviceUrl =~ /^service:\/\//) {
		if(_serviceExists($serviceId)) {
			my $replacementUrl = $localServices->{$serviceId};
			#$log->debug("Replacing: $serviceUrl based on $serviceId prefix: ".$replacementUrl);
			$serviceUrl =~ s/^service:\/\/[^\/]*\//$replacementUrl\//;
			#$log->debug("Replaced with: $serviceUrl");
		}elsif($serviceId eq $prefs->get('uuid')) {
			# let's increase reliability for local content service
			$log->debug("Unable to resolve using getServiceInformation, resolving locally");
			my $serverAddress = Slim::Utils::Network::serverAddr();
			($serverAddress) = split /:/, $serverAddress;
			
			if ($serverPrefs->get('authorize')) {
				my $password = Crypt::Tea::decrypt($prefs->get('password'),$KEY);
				$serverAddress = $serverPrefs->get('username').":".$password."@".$serverAddress;
			}
		
			$serverAddress .= ":" . $serverPrefs->get('httpport');
			my $replacementUrl = 'http://'.$serverAddress;
			$serviceUrl =~ s/^service:\/\/[^\/]*\//$replacementUrl\//;
			
		}

	}
	return $serviceUrl;
}

sub responseCallback {
	my $response = shift;
	if(defined($localServiceRequestIds->{$response->{'id'}})) {
		my $serviceId = $localServiceRequestIds->{$response->{'id'}}; 
		$localRequestedServices->{$serviceId} = undef;
		$localServiceRequestIds->{$response->{'id'}} = undef;
		_setService($serviceId,$response->{'result'});
		return 1;
	}
	return undef;
}
sub getService {
	my $player = shift;
	my $serviceId = shift;
	my $requestIdProvider = shift;

	if(!_serviceExists($serviceId)) {
		if(!$localRequestedServices->{$serviceId}) {
			my $requestId = &{$requestIdProvider}();
			$localServiceRequestIds->{$requestId} = $serviceId;
			$localRequestedServices->{$serviceId} = $requestId;
		
			my $playerConfiguration = $prefs->get('player_'.$player->id) || {};
			
		    my $serverIP = Slim::Utils::IPDetect::IP();
			my $params = { timeout => 35 };
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					$log->warn("Successfully sent getServiceInformation request");
				},
				sub {
					$log->warn("Error when sending getServiceInformation request");
					my $requestId = $localRequestedServices->{$serviceId};
					$localRequestedServices->{$serviceId} = undef;
					$localServiceRequestIds->{$requestId} = undef;
				},
				$params
			)->post("http://".$serverIP.":".$prefs->get('daemonPort')."/sendMessage/".$serviceId."/2",'Content-Type' => 'application/json','Authorization'=>$playerConfiguration->{'id'},to_json({
				'jsonrpc' => "2.0",
				'id' => $localRequestedServices->{$serviceId},
				'method' => 'getServiceInformation'
				}));
		}
	}
}

sub handleDiscoveryJSON {
	my ($httpClient, $httpResponse) = @_;

        # make sure we're connected
        if (!$httpClient->connected()) {
                $log->warn("Aborting, client not connected: $httpClient");
                return;
        }

        # cancel any previous subscription on this connection
        # we must have a context defined and a subscription defined
        if (defined(Plugins::IckStreamPlugin::JsonHandler::getContext($httpClient)) && 
                Slim::Control::Request::unregisterAutoExecute($httpClient)) {
        
                # we want to send a last chunk to close the connection as per HTTP...
                # a subscription is essentially a never ending response: we're receiving here
                # a new request (aka pipelining) so we want to be nice and close the previous response
                
                # we cannot have a subscription if this is not a long lasting, keep-open, chunked connection.
                
                Slim::Web::HTTP::addHTTPLastChunk($httpClient, 0);
        }

        # get the request data (POST for JSON 2.0)
        my $input = $httpResponse->request()->content();

        $log->is_debug && $log->debug("POST data: [$input]");

        # create a hash to store our context
        my $uri = $httpResponse->request()->uri();
        my $query = $uri->query();

		my $httpParams = {};
		foreach my $param (split /\&/, $query) {

			if ($param =~ /([^=]+)=(.*)/) {
				my $name  = Slim::Utils::Misc::unescape($1, 1);
				my $value = Slim::Utils::Misc::unescape($2, 1);
				$httpParams->{$name} = $value;
			}
		}
		$log->is_debug && $log->debug( "Device information: " . Data::Dump::dump($httpParams) );
  
		# Get player for uuid
		my $players = $prefs->get('players');
		my $player = undef;
		if(defined($httpParams->{'toDeviceId'}) && $players->{$httpParams->{'toDeviceId'}}) {
			$player = Slim::Player::Client::getClient($players->{$httpParams->{'toDeviceId'}});
		}

		my $procedure = from_json($input);

                if ( main::DEBUGLOG && $log->is_debug ) {
                $log->debug( "JSON parsed procedure: " . Data::Dump::dump($procedure) );
        }

		my $service = $httpParams->{'fromService'};
		$log->debug("GOT: ".$procedure->{'status'}." from ".$httpParams->{'fromDeviceId'}."(".$service.")");		
		if($service & 4) {
			if($procedure->{'status'} eq 'CONNECTED') {
				getService($player, $httpParams->{'fromDeviceId'}, \&Plugins::IckStreamPlugin::Plugin::getNextRequestId);
			}elsif($procedure->{'status'} eq 'DISCONNECTED') {
				removeService($httpParams->{'fromDeviceId'});
			}
		}
		
	    Slim::Web::HTTP::closeHTTPSocket($httpClient);
	    return;
}


1;

