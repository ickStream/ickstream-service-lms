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

package Plugins::IckStreamPlugin::CloudServiceManager;

use strict;
use Scalar::Util qw(blessed);
use Plugins::IckStreamPlugin::Plugin;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use JSON::XS::VersionOneAndTwo;

my $log   = logger('plugin.ickstream');
my $prefs = preferences('plugin.ickstream');

my $cloudServices = {};


sub getService {
	my $client = shift;
	my $serviceId = shift;
	my $callback = shift;
	
	if(defined($cloudServices->{$client->id}) && defined($cloudServices->{$client->id}->{$serviceId})) {
		$callback->(1);
	}else {
		_refreshContentServices($client,sub {
			if(defined($cloudServices->{$client->id}) && defined($cloudServices->{$client->id}->{$serviceId})) {
				$callback->(1);
			}else {
				$callback->(0);
			}
		});
	}
}

sub getServiceUrl {
	my $client = shift;
	my $serviceId = shift;
	
	if(defined($cloudServices->{$client->id}) && defined($cloudServices->{$client->id}->{$serviceId})) {
		return $cloudServices->{$client->id}->{$serviceId};
	}else {
		return undef;
	}
}

sub _refreshContentServices {
	my $client = shift;
	my $callback = shift;
	
	my $playerConfiguration = $prefs->get('player_'.$client->id) || {};
	my $cloudCoreUrl = $playerConfiguration->{'cloudCoreUrl'} || 'http://api.ickstream.com/ickstream-cloud-core/jsonrpc';
	
	if(defined($playerConfiguration->{'accessToken'})) {
		$log->info("Retrieve content services from cloud");
		Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						my $jsonResponse = from_json($http->content);
						my $cloudServiceEntries = {};
						if($jsonResponse->{'result'} && $jsonResponse->{'result'}->{'items'}) {
							foreach my $service (@{$jsonResponse->{'result'}->{'items'}}) {
								$cloudServiceEntries->{$service->{'id'}} = $service->{'url'};
							}
						}
						$cloudServices->{$client->id} = $cloudServiceEntries;
						$log->info("Received services: ".Data::Dump::dump($cloudServiceEntries));
						$callback->(1);
					},
					sub {
						$log->info("Failed to retrieve content services from cloud");
						$callback->(0);
					},
					undef
				)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$playerConfiguration->{'accessToken'},to_json({
					'jsonrpc' => '2.0',
					'id' => 1,
					'method' => 'findServices',
					'params' => {
						'type' => 'content'
					}
				}));
	}else {
		$log->warn("No access token, can't retrieve services from cloud");
		$callback->(0);
	}

}


1;

