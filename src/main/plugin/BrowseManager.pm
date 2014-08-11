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

package Plugins::IckStreamPlugin::BrowseManager;

use strict;
use Scalar::Util qw(blessed);
use Plugins::IckStreamPlugin::Plugin;
use Plugins::IckStreamPlugin::ItemCache;
use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Misc;
use Slim::Utils::Strings qw(string cstring);
use JSON::XS::VersionOneAndTwo;
use Data::Dumper;
use Tie::Cache::LRU;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ickstream.browse',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ICKSTREAM_BROWSE_LOG',
});
my $prefs = preferences('plugin.ickstream');

my $cloudServiceEntries = {};
my $cloudServiceProtocolEntries = {};
my $cloudServiceMenus = {};

tie my %cache, 'Tie::Cache::LRU', 10;
use constant CACHE_TIME => 300;

sub getAccessToken {
	my $player = shift;
	
	if(defined($player)) {
		my $playerConfiguration = $prefs->get('player_'.$player->id) || {};
		if(defined($playerConfiguration->{'accessToken'})) {
			return $playerConfiguration->{'accessToken'};
		}
	}
	return undef;
	#my $accessToken = $prefs->get('accessToken');
	#return $accessToken;
}

sub _getCloudCoreUrl {
	my $player = shift;
	
	my $playerConfiguration = $prefs->get('player_'.$player->id) || {};
	my $cloudCoreUrl = $playerConfiguration->{'cloudCoreUrl'} || 'https://api.ickstream.com/ickstream-cloud-core/jsonrpc';
	return $cloudCoreUrl;
}

sub sliceResult {
	my $result = shift;
	my $args = shift;
	my $forcedOffset = shift;
	
	my $index = $forcedOffset;
	if(!defined($index)) {
		$index = getOffset($args);
	}
	my @resultItems = ();
	if(defined($args->{'quantity'}) && $args->{'quantity'} ne "") {
		$log->debug("Getting items $index..".$args->{'quantity'});
		@resultItems = @$result;
		@resultItems = splice @resultItems,$index,$args->{'quantity'};
	}else {
		$log->debug("Getting items $index..");
		@resultItems = @$result;
		@resultItems = splice @resultItems,$index;
	}
	return \@resultItems;
}

sub getOffset {
	my $args = shift;

	my $index = 0;
	if(defined($args->{'index'})) {
		$index = int($args->{'index'});
	}
	return $index;
}

sub playerChange {
        # These are the two passed parameters
        my $request=shift;
        my $player = $request->client();

		if(defined($player) && ($request->isCommand([['client'],['new']]) || $request->isCommand([['client'],['reconnect']]))) {
			Plugins::IckStreamPlugin::LicenseManager::getLicense($player,
				sub {
					my $accessToken = getAccessToken($player);
					if(defined($accessToken)) {
						$log->info("Initialize browsing for ".$player->name());
						init($player)
					}
				},
				sub {});
		}
}

sub init {
	my $player = shift;
	my $accessToken = getAccessToken($player);
	if(defined($accessToken)) {
		if(!defined($cloudServiceEntries->{$player->id})) {
			my $cloudCoreUrl = _getCloudCoreUrl($player);
			my $requestParams = to_json({
						'jsonrpc' => '2.0',
						'id' => 1,
						'method' => 'findServices',
						'params' => {
							'type' => 'content'
						}
					});
			$log->info("Retrieve content services from cloud for ".$player->name());
			my $httpParams = { timeout => 35 };
			Slim::Networking::SimpleAsyncHTTP->new(
				sub {
					my $http = shift;
					my $jsonResponse = from_json($http->content);
	
					$cloudServiceEntries->{$player->id} = {};
					$cloudServiceMenus->{$player->id} = {};
					$cloudServiceProtocolEntries->{$player->id} = {};
			
					my @services = ();
					if($jsonResponse->{'result'} && $jsonResponse->{'result'}->{'items'}) {
						foreach my $service (@{$jsonResponse->{'result'}->{'items'}}) {
							if($jsonResponse->{'result'} && $jsonResponse->{'result'}->{'items'}) {
								foreach my $service (@{$jsonResponse->{'result'}->{'items'}}) {
									$cloudServiceEntries->{$player->id}->{$service->{'id'}} = $service;
								}
							}
								
							getProtocolDescription2($player, $service->{'id'},
								sub {
									my $serviceId = shift;
									my $protocolEntries = shift;
									
									getPreferredMenus($player, $service->{'id'},
										sub {
											my $serviceId = shift;
											my $preferredMenus = shift;
											
											foreach my $menu (@{$preferredMenus}) {
												if($menu->{'type'} eq 'search') {
													my $searchRequests = findSearchRequests($menu,$protocolEntries);
													if(scalar(@$searchRequests)>0) {
														$log->debug("Added search provider for: ".$service->{'name'});
														Slim::Menu::GlobalSearch->registerInfoProvider('ickstream_'.$service->{'id'} => (
															func => sub {
											                	my ( $client, $tags ) = @_;
											                	return searchMenu($client,$tags,$service, $searchRequests);
															}
														));
													}
												}
											}
										},
										sub {
											my $http = shift;
											my $error = shift;
											$log->warn("Failed to retrieve preferred menus from cloud for ".$player->name().": ".$error);
										});
								},
								sub {
									my $http = shift;
									my $error = shift;
									$log->warn("Failed to retrieve protocol description from cloud for ".$player->name().": ".$error);
								});
						}
					}else {
						$log->warn("Error: ".Dumper($jsonResponse));
					}
				},
				sub {
					my $http = shift;
					my $error = shift;
					$log->warn("Failed to retrieve content services from cloud for ".$player->name().": ".$error);
				},
				$httpParams
			)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);
		}
	}
}

sub findSearchRequests {
	my $menu = shift;
	my $protocolEntries = shift;
	my $searchRequests = shift;
	
	if(!defined($searchRequests)) {
		my @empty = ();
		$searchRequests = \@empty;
	}
	
	if(defined($menu->{'childRequest'})) {
		my $request = $protocolEntries->{$menu->{'childRequest'}->{'request'}};
		if(defined($request)) {
			my $searchRequest = {
				'contextId' => $request->{'values'}->{'contextId'},
				'name' => $menu->{'text'},
				'request' => $menu->{'childRequest'}->{'request'},
			};
			if(defined($menu->{'childRequest'}->{'childItems'})) {
				$searchRequest->{'childItems'} = $menu->{'childRequest'}->{'childItems'};
			}
			if(defined($menu->{'childRequest'}->{'childRequest'})) {
				$searchRequest->{'childRequest'} = $menu->{'childRequest'}->{'childRequest'};
			}
			
			push @$searchRequests,$searchRequest;
		}
	}elsif(defined($menu->{'childItems'})) {
		foreach my $childItem (@{$menu->{'childItems'}}) {
			if($childItem->{'type'} eq 'search') {
				findSearchRequests($childItem,$protocolEntries,$searchRequests);
			}
		}
	}
	return $searchRequests;	
}

sub searchMenu {
	my $client = shift;
	my $tags = shift;
	my $service = shift;
	my $searchRequests = shift;
	
	my @result = ();
	foreach my $searchRequest (@$searchRequests) {
		my $menu = {
			name => $searchRequest->{'name'},
			url => \&searchItemMenu,
			passthrough => [$service->{'id'},$searchRequest,$tags->{search}]
		};
		push @result,$menu;
	}
	return {
		name => $service->{'name'}." via ickStream",
		items => \@result
	};
	
}

sub topLevel {
        my ($client, $cb, $args) = @_;
        
        my $params = $args->{params};
        
		my $accessToken = getAccessToken($client);
		
		if(!defined($accessToken)) {
			$cb->({items => [{
                        name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                        type => 'textarea',
                }]});
		}else {
				my $requestParams = to_json({
							'jsonrpc' => '2.0',
							'id' => 1,
							'method' => 'findServices',
							'params' => {
								'type' => 'content'
							}
						});
				my $cacheKey = "$accessToken.$requestParams";
				if((time() - $cache{$cacheKey}->{'time'}) < CACHE_TIME) {
					$log->debug("Using cached content services from cloud for: ".Dumper($args));
					my $items = $cache{$cacheKey}->{'data'};
					processTopLevel($client, $items,$args, $cb);
					return;
				}
				my $cloudCoreUrl = _getCloudCoreUrl($client);
				$log->info("Retrieve content services from cloud using ".$cloudCoreUrl);
				my $httpParams = { timeout => 35 };
				Slim::Networking::SimpleAsyncHTTP->new(
							sub {
								my $http = shift;
								my $jsonResponse = from_json($http->content);
								$log->debug("Store in cache with key: ".$cacheKey);
								$cache{$cacheKey} = { 'data' => $jsonResponse, 'time' => time()};
								processTopLevel($client, $jsonResponse,$args, $cb);
							},
							sub {
								my $http = shift;
								my $error = shift;
								$log->warn("Failed to retrieve content services from cloud: ".$error);
								$cb->(items => [{
									name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
									type => 'textarea',
				                }]);
							},
							$httpParams
						)->post($cloudCoreUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);

		}
}

sub processTopLevel {
	my $client = shift;
	my $jsonResponse = shift;
	my $args = shift;
	my $cb = shift;
	
	$cloudServiceEntries = {};
	$cloudServiceEntries->{$client->id} = {};
	my @services = ();
	if($jsonResponse->{'result'} && $jsonResponse->{'result'}->{'items'}) {
		foreach my $service (@{$jsonResponse->{'result'}->{'items'}}) {
			$log->debug("Found ".$service->{'name'});
			$cloudServiceEntries->{$client->id}->{$service->{'id'}} = $service;
			my $serviceEntry = {
				name => $service->{'name'},
				url => \&preferredServiceMenu,
				passthrough => [$service->{'id'}]
			};
			push @services,$serviceEntry;
		}
		$log->debug("Got ".scalar(@services)." items");
	}else {
		$log->warn("Error: ".Dumper($jsonResponse));
	}
	if(scalar(@services)>0) {
		my $resultItems = sliceResult(\@services,$args);
		$log->debug("Returning: ".scalar(@$resultItems). " items");
		$cb->({items => $resultItems, offset => getOffset($args)});
	}else {
		$cb->({items => [{
			name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_ADD_SERVICES'),
			type => 'textarea',
              }]});
	}
}

sub getProtocolDescription2 {
	my $client = shift;
	my $serviceId = shift;
	my $successCb = shift;
	my $errorCb = shift;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		if(defined($client)) {
			$log->warn("Player ".$client->name()." isn't registered");
		}else {
			$log->warn("This LMS isn't registered");
		}
		&{$errorCb}($serviceId);
	}

	if(defined($cloudServiceProtocolEntries->{$client->id}->{$serviceId})) {
		&{$successCb}($serviceId,$cloudServiceProtocolEntries->{$client->id}->{$serviceId});
	}else {
		$log->info("Retrieve protocol description for ".$serviceId." for ".$client->name);
		my $serviceUrl = $cloudServiceEntries->{$client->id}->{$serviceId}->{'url'};
		$log->info("Retriving data from: $serviceUrl");
		my $httpParams = { timeout => 35 };
		Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						my $jsonResponse = from_json($http->content);
						my @menus = ();
						if($jsonResponse->{'result'}) {
							$cloudServiceProtocolEntries->{$client->id}->{$serviceId} = {};
							foreach my $context (@{$jsonResponse->{'result'}->{'items'}}) {
								foreach my $type (keys %{$context->{'supportedRequests'}}) {
									my $requests = $context->{'supportedRequests'}->{$type};
									foreach my $requestId (keys %$requests) {
										$cloudServiceProtocolEntries->{$client->id}->{$serviceId}->{$requestId} = $requests->{$requestId};
										if(!defined($cloudServiceProtocolEntries->{$client->id}->{$serviceId}->{$requestId}->{'values'})) {
											$cloudServiceProtocolEntries->{$client->id}->{$serviceId}->{$requestId}->{'values'} = {};
										}
										if($type ne 'none') {
											$cloudServiceProtocolEntries->{$client->id}->{$serviceId}->{$requestId}->{'values'}->{'type'} = $type;
										}
										$cloudServiceProtocolEntries->{$client->id}->{$serviceId}->{$requestId}->{'values'}->{'contextId'} = $context->{'contextId'};
									}
								}
							}
							&{$successCb}($serviceId,$cloudServiceProtocolEntries->{$client->id}->{$serviceId});
						}else {
							$log->warn("Failed to retrieve protocol description for ".$serviceId.": ".Dumper($jsonResponse));
							&{$errorCb}($serviceId);
						}
					},
					sub {
						my $http = shift;
						my $error = shift;
						$log->warn("Failed to retrieve protocol description for ".$serviceId.": ".$error);
						&{$errorCb}($serviceId);
					},
					$httpParams
				)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,to_json({
					'jsonrpc' => '2.0',
					'id' => 1,
					'method' => 'getProtocolDescription2',
					'params' => {
					}
				}));
		
	}
}
sub getPreferredMenus {
	my $client = shift;
	my $serviceId = shift;
	my $successCb = shift;
	my $errorCb = shift;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		if(defined($client)) {
			$log->warn("Player ".$client->name()." isn't registered");
		}else {
			$log->warn("This LMS isn't registered");
		}
		&{$errorCb}($serviceId);
	}

	if(defined($cloudServiceMenus->{$client->id}->{$serviceId})) {
		&{$successCb}($serviceId,$cloudServiceMenus->{$client->id}->{$serviceId});
	}else {
		$log->info("Retrieve preferred menus for ".$serviceId." for ".$client->name);
		my $serviceUrl = $cloudServiceEntries->{$client->id}->{$serviceId}->{'url'};
		$log->info("Retriving data from: $serviceUrl");
		my $httpParams = { timeout => 35 };
		Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						my $jsonResponse = from_json($http->content);
						my @menus = ();
						if($jsonResponse->{'result'}) {
							$cloudServiceMenus->{$client->id}->{$serviceId} = $jsonResponse->{'result'}->{'items'};
							&{$successCb}($serviceId,$cloudServiceMenus->{$client->id}->{$serviceId});
						}else {
							$log->warn("Failed to retrieve preferred menus for ".$serviceId.": ".Dumper($jsonResponse));
							&{$errorCb}($serviceId);
						}
					},
					sub {
						my $http = shift;
						my $error = shift;
						$log->warn("Failed to retrieve preferred menus for ".$serviceId.": ".$error);
						&{$errorCb}($serviceId);
					},
					$httpParams
				)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,to_json({
					'jsonrpc' => '2.0',
					'id' => 1,
					'method' => 'getPreferredMenus',
					'params' => {
					}
				}));
		
	}
}

sub preferredServiceMenu {
	my ($client, $cb, $args, $serviceId) = @_;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		$cb->({items => [{
                       name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                       type => 'textarea',
               }]});
	}else {
		getProtocolDescription2($client, $serviceId,
			sub {
				my $serviceId = shift;
				my $protocolEntries = shift;
				
				getPreferredMenus($client, $serviceId,
					sub {
						my $serviceId = shift;
						my $preferredMenus = shift;

						my @menus = ();
						my $noOfChildItemsMenus = 0;
						my $noOfChildRequestMenus = 0;
						foreach my $menu (@$preferredMenus) {
							if($menu->{'type'} eq 'browse') {
								if(defined($menu->{'childItems'})) {
									my $entry = {
										'name' => $menu->{'text'},
										'url' => \&serviceChildItemsMenu,
										'passthrough' => [
											$serviceId,
											$menu->{'childItems'}
										]
									};
									$noOfChildItemsMenus++;
									push @menus,$entry;
								}elsif(defined($menu->{'childRequest'})) {
									my $entry = {
										'name' => $menu->{'text'},
										'url' => \&serviceChildRequestMenu,
										'passthrough' => [
											$serviceId,
											$menu->{'childRequest'}
										]
									};
									$noOfChildRequestMenus++;
									push @menus,$entry;
								}
							}elsif($menu->{'type'} eq 'search') {
								my $searchRequests = findSearchRequests($menu,$protocolEntries);
								
								if(scalar(@$searchRequests)==1) {
									my $entry = {
										'name' => $menu->{'text'},
										'type' => 'search',
										'url' => \&searchItemMenu,
										'passthrough' => [$serviceId,$searchRequests->[0]]
									};
									push @menus,$entry;
									
								}else {
									my $entry = {
										'name' => $menu->{'text'},
										'type' => 'search',
										'url' => sub {
											my ($client, $cb, $params) = @_;
											
											my $searchMenu = searchMenu($client, {
													search => lc($params->{search})
												},
												$cloudServiceEntries->{$client->id}->{$serviceId},
												$searchRequests);
											
											$cb->({
												items => $searchMenu->{items}
											});
										}
									};
									push @menus,$entry;
								}
							}
						}

						if(scalar(@menus)>0) {
							if(scalar(@menus)==1 && $noOfChildRequestMenus==1) {
								my $menu = @menus[0];
								serviceChildRequestMenu($client,$cb,$args,$serviceId,$menu->{'passthrough'}[1]);
							}else {
								my $resultItems = sliceResult(\@menus,$args);
								$log->debug("Returning: ".scalar(@$resultItems). " items");
								$cb->({items => $resultItems, offset => getOffset($args)});
							}
						}else {
							$cb->({items => [{
								name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
								type => 'textarea',
			                }]});
						}
					},
					sub {
						$log->warn("Failed to retrieve content services from cloud");
						$cb->(items => [{
							name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
							type => 'textarea',
		                }]);
					});

			},
			sub {
				$log->warn("Failed to retrieve content services from cloud");
				$cb->(items => [{
					name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
					type => 'textarea',
                }]);
			});
	}
	        
}


sub serviceChildItemsMenu {
	my ($client, $cb, $args, $serviceId, $childItems,$parent) = @_;

	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		$cb->({items => [{
                       name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                       type => 'textarea',
               }]});
	}else {
		getProtocolDescription2($client, $serviceId,
			sub {
				my $serviceId = shift;
				my $protocolDescription = shift;
				my @menus = ();
				
				foreach my $menu (@$childItems) {
					if($menu->{'type'} ne 'search') {
						if(defined($menu->{'childItems'})) {
							my $entry = {
								'name' => $menu->{'text'},
								'url' => \&serviceChildItemsMenu,
								'passthrough' => [
									$serviceId,
									$menu->{'childItems'},
									$parent
								]
							};
							push @menus,$entry;
						}elsif(defined($menu->{'childRequest'})) {
							my $entry = {
								'name' => $menu->{'text'},
								'url' => \&serviceChildRequestMenu,
								'passthrough' => [
									$serviceId,
									$menu->{'childRequest'},
									$parent
								]
							};
							push @menus,$entry;
						}
					}
				}

				if(scalar(@menus)>0) {
					my $resultItems = sliceResult(\@menus,$args);
					$log->debug("Returning: ".scalar(@$resultItems). " items");
					$cb->({items => $resultItems, offset => getOffset($args)});
				}else {
					$cb->({items => [{
						name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
						type => 'textarea',
	                }]});
				}
			},
			sub {
				$log->warn("Failed to retrieve content services from cloud");
				$cb->(items => [{
					name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
					type => 'textarea',
                }]);
			});
	}
}

sub serviceChildRequestMenu {
	my ($client, $cb, $args, $serviceId, $childRequest, $parent) = @_;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		$cb->({items => [{
                       name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                       type => 'textarea',
               }]});
	}else {
		getProtocolDescription2($client, $serviceId,
			sub {
				my $serviceId = shift;
				my $protocolDescription = shift;
				
				my $serviceUrl = $cloudServiceEntries->{$client->id}->{$serviceId}->{'url'};
				my $request = $protocolDescription->{$childRequest->{'request'}};

				my $params = {};
				foreach my $param (@{$request->{'parameters'}}) {
					if(defined($request->{'values'}->{$param})) {
						$params->{$param} = $request->{'values'}->{$param};
					}else {
						$params->{$param} = getParameterFromParent($param,$parent);
					}
				}
				if(defined($args->{'quantity'}) && $args->{'quantity'} ne "") {
					$params->{'count'} = int($args->{'quantity'});
				}
				if(defined($args->{'index'}) && $args->{'index'} ne "") {
					$params->{'offset'} = int($args->{'index'});
				}else {
					$params->{'offset'} = 0;
				}
				my $requestParams = to_json({
							'jsonrpc' => '2.0',
							'id' => 1,
							'method' => 'findItems',
							'params' => $params
						});
				$log->debug("Using: ".Dumper($requestParams));
				my $cacheKey = "$accessToken.$serviceId.$requestParams";
				$log->debug("Check cache with key: ".$cacheKey);
				if((time() - $cache{$cacheKey}->{'time'}) < CACHE_TIME) {
					$log->debug("Using cached items from: $serviceUrl for: ".Dumper($args));
					my $jsonResponse = $cache{$cacheKey}->{'data'};
					processServiceChildRequestMenu($client, $serviceId,$childRequest,$parent, $jsonResponse,$args, $cb);
					return;
				}
				$log->info("Retriving items from: $serviceUrl");
				my $httpParams = { timeout => 35 };
				Slim::Networking::SimpleAsyncHTTP->new(
							sub {
								my $http = shift;
								my $jsonResponse = from_json($http->content);
								$log->debug("Store in cache with key: ".$cacheKey);
								$cache{$cacheKey} = { 'data' =>$jsonResponse, 'time' => time()};
								processServiceChildRequestMenu($client, $serviceId,$childRequest,$parent, $jsonResponse,$args, $cb);
							},
							sub {
								my $http = shift;
								my $error = shift;
								$log->warn("Failed to retrieve content service items from cloud: ".$error);
								$cb->(items => [{
									name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
									type => 'textarea',
				                }]);
							},
							$httpParams
						)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);					
		},
		sub {
			$log->warn("Failed to retrieve content services from cloud");
			$cb->(items => [{
				name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
				type => 'textarea',
               }]);
		});
	}
}

sub processServiceChildRequestMenu {
	my $client = shift;
	my $serviceId = shift;
	my $childRequest = shift;
	my $parent = shift;
	my $jsonResponse = shift;
	my $args = shift;
	my $cb = shift;

	my @menus = ();
	my $totalItems = undef;
	if($jsonResponse->{'result'}) {
		if(defined($jsonResponse->{'result'}->{'countAll'})) {
			$totalItems =$jsonResponse->{'result'}->{'countAll'};
		}
		foreach my $item (@{$jsonResponse->{'result'}->{'items'}}) {
			my $menu;
			if(defined($childRequest->{'childItems'})) {
				$menu = {
					'name' => $item->{'text'},
					'url' => \&serviceChildItemsMenu,
					'passthrough' => [
						$serviceId,
						$childRequest->{'childItems'},
						{
							'type' => $item->{'type'},
							'id' => $item->{'id'},
							'preferredChildRequest' => $item->{'preferredChildRequest'},
							'parent' => $parent
						}
					]
				};
			}elsif(defined($childRequest->{'childRequest'})) {
				$menu = {
					'name' => $item->{'text'},
					'url' => \&serviceChildRequestMenu,
					'passthrough' => [
						$serviceId,
						$childRequest->{'childRequest'},
						{
							'type' => $item->{'type'},
							'id' => $item->{'id'},
							'preferredChildRequest' => $item->{'preferredChildRequest'},
							'parent' => $parent
						}
					]
				};
			}elsif(defined($item->{'preferredChildRequest'})) {
				$menu = {
					'name' => $item->{'text'},
					'url' => \&serviceChildRequestMenu,
					'passthrough' => [
						$serviceId,
						{
							'request' => $item->{'preferredChildRequest'}
						},
						{
							'type' => $item->{'type'},
							'id' => $item->{'id'},
							'preferredChildRequest' => $item->{'preferredChildRequest'},
							'parent' => $parent
						}
					]
				};
			}else {
				$menu = {
					'name' => $item->{'text'}
				};
			}
			if(defined($item->{'image'})) {
				$menu->{'image'} = $item->{'image'};
			}

			if($item->{'type'} ne 'track' && $item->{'type'} ne 'stream') {
				if($item->{'type'} eq 'album' || $item->{'type'} eq 'playlist') {
					$menu->{'type'} = 'playlist';
					if(defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0]) && ($parent->{'type'} ne 'artist' || !defined($parent->{'id'}))) {
						$menu->{'line1'} = $item->{'text'};
						$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'};						
					}elsif(defined($item->{'itemAttributes'}->{'year'})) {
						$menu->{'line1'} = $item->{'text'};
						$menu->{'line2'} = $item->{'itemAttributes'}->{'year'};						
					}
				}
			}else {
	        	Plugins::IckStreamPlugin::ItemCache::setItemInCache($item->{'id'},$item);
				$menu->{'play'} = 'ickstream://'.$item->{'id'};
				$menu->{'type'} = 'audio';
				$menu->{'on_select'} = 'play';
				$menu->{'playall'} = 1;
				if(defined($item->{'itemAttributes'}->{'album'}) && defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0]) && ($parent->{'type'} ne 'album' || !defined($parent->{'id'}))) {
					$menu->{'line1'} = $item->{'text'};
					$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'}." - ".$item->{'itemAttributes'}->{'album'}->{'name'};
				}elsif(defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0])) {
					$menu->{'line1'} = $item->{'text'};
					$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'};
				}elsif(defined($item->{'itemAttributes'}->{'album'})) {
					$menu->{'line1'} = $item->{'text'};
					$menu->{'line2'} = $item->{'itemAttributes'}->{'album'}->{'name'};
				}
					
			}
			push @menus,$menu;
		}
		$log->debug("Got ".scalar(@menus)." items");
	}else {
		$log->warn("Error: ".Dumper($jsonResponse));
	}
	if(scalar(@menus)>0) {
		my $resultItems = sliceResult(\@menus,$args,0);
		if(defined($totalItems)) {
			$log->debug("Returning: ".scalar(@$resultItems). " items of ".$totalItems);
			$cb->({items => $resultItems, total => $totalItems, offset => getOffset($args)});
		}else {
			$log->debug("Returning: ".scalar(@$resultItems). " items");
			$cb->({items => $resultItems, offset => getOffset($args)});
		}
	}else {
		$cb->({items => [{
			name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
			type => 'textarea',
              }]});
	}
}

sub searchItemMenu {
	my ($client, $cb, $args, $serviceId, $searchRequest, $search) = @_;
	
	my $accessToken = getAccessToken($client);
	if(!defined($accessToken)) {
		$cb->({items => [{
                       name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
                       type => 'textarea',
               }]});
	}else {
		getProtocolDescription2($client, $serviceId,
			sub {
				my $serviceId = shift;
				my $protocolDescription = shift;
				
				my $serviceUrl = $cloudServiceEntries->{$client->id}->{$serviceId}->{'url'};
				my $request = $protocolDescription->{$searchRequest->{'request'}};

				my $params = {
				};
				foreach my $param (@{$request->{'parameters'}}) {
					if($param eq 'search') {
						if(defined($search)) {
							$params->{'search'} = $search;
						}else {
							$params->{'search'} = $args->{'search'};
						}
					}else { 
						$params->{$param} = $request->{'values'}->{$param};
					}
				}
				if(defined($args->{'quantity'}) && $args->{'quantity'} ne "") {
					$params->{'count'} = int($args->{'quantity'});
				}
				if(defined($args->{'index'}) && $args->{'index'} ne "") {
					$params->{'offset'} = int($args->{'index'});
				}else {
					$params->{'offset'} = 0;
				}
				my $requestParams = to_json({
							'jsonrpc' => '2.0',
							'id' => 1,
							'method' => 'findItems',
							'params' => $params
						});
				$log->debug("Using: ".Dumper($requestParams));
				my $cacheKey = "$accessToken.$serviceId.$requestParams";
				$log->debug("Check cache with key: ".$cacheKey);
				if((time() - $cache{$cacheKey}->{'time'}) < CACHE_TIME) {
					$log->debug("Using cached items from: $serviceUrl for: ".Dumper($args));
					my $jsonResponse = $cache{$cacheKey}->{'data'};
					processServiceItemMenu($client,$serviceId,$searchRequest, $jsonResponse,$args,$cb);
					return;
				}
				$log->info("Search ".$params->{'type'}." from: $serviceUrl");
				my $httpParams = { timeout => 35 };
				Slim::Networking::SimpleAsyncHTTP->new(
					sub {
						my $http = shift;
						my $jsonResponse = from_json($http->content);
						$log->debug("Store in cache with key: ".$cacheKey);
						$cache{$cacheKey} = { 'data' =>$jsonResponse, 'time' => time()};
						processServiceItemMenu($client,$serviceId,$searchRequest, $jsonResponse,$args,$cb);
					},
					sub {
						my $http = shift;
						my $error = shift;
						$log->warn("Failed to retrieve content service items from cloud: ".$error);
						$cb->(items => [{
							name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
							type => 'textarea',
		                }]);
					},
					$httpParams
				)->post($serviceUrl,'Content-Type' => 'application/json','Authorization'=>'Bearer '.$accessToken,$requestParams);					
		},
		sub {
			$log->warn("Failed to retrieve content services from cloud");
			$cb->(items => [{
				name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_REQUIRES_CREDENTIALS'),
				type => 'textarea',
               }]);
		});
	}
}

sub processServiceItemMenu {
	my $client = shift;
	my $serviceId = shift;
	my $searchRequest = shift;
	my $jsonResponse = shift;
	my $args = shift;
	my $cb = shift;
	
	my @menus = ();
	my $totalItems = undef;
	if($jsonResponse->{'result'}) {
		if(defined($jsonResponse->{'result'}->{'countAll'})) {
			$totalItems =$jsonResponse->{'result'}->{'countAll'};
		}
		foreach my $item (@{$jsonResponse->{'result'}->{'items'}}) {
			my $menu;
			if(defined($searchRequest->{'childItems'})) {
				$menu = {
					'name' => $item->{'text'},
					'url' => \&serviceChildItemsMenu,
					'passthrough' => [
						$serviceId,
						$searchRequest->{'childItems'},
						{
							'type' => $item->{'type'},
							'id' => $item->{'id'},
							'preferredChildRequest' => $item->{'preferredChildRequest'},
							'parent' => undef
						}
					]
				};
			}elsif(defined($searchRequest->{'childRequest'})) {
				$menu = {
					'name' => $item->{'text'},
					'url' => \&serviceChildRequestMenu,
					'passthrough' => [
						$serviceId,
						$searchRequest->{'childRequest'},
						{
							'type' => $item->{'type'},
							'id' => $item->{'id'},
							'preferredChildRequest' => $item->{'preferredChildRequest'},
							'parent' => undef
						}
					]
				};
			}elsif(defined($item->{'preferredChildRequest'})) {
				$menu = {
					'name' => $item->{'text'},
					'url' => \&serviceChildRequestMenu,
					'passthrough' => [
						$serviceId,
						{
							'request' => $item->{'preferredChildRequest'}
						},
						{
							'type' => $item->{'type'},
							'id' => $item->{'id'},
							'preferredChildRequest' => $item->{'preferredChildRequest'},
							'parent' => undef
						}
					]
				};
			}else {
				$menu = {
					'name' => $item->{'text'}
				};
			}
			
			if(defined($item->{'image'})) {
				$menu->{'image'} = $item->{'image'};
			}
			if($item->{'type'} ne 'track' && $item->{'type'} ne 'stream') {
				if($item->{'type'} eq 'album' || $item->{'type'} eq 'playlist') {
					$menu->{'type'} = 'playlist';
					if(defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0])) {
						$menu->{'line1'} = $item->{'text'};
						$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'};						
					}elsif(defined($item->{'itemAttributes'}->{'year'})) {
						$menu->{'line1'} = $item->{'text'};
						$menu->{'line2'} = $item->{'itemAttributes'}->{'year'};						
					}
				}
			}else {
	        	Plugins::IckStreamPlugin::ItemCache::setItemInCache($item->{'id'},$item);
				$menu->{'play'} = 'ickstream://'.$item->{'id'};
				$menu->{'type'} = 'audio';
				$menu->{'on_select'} => 'play';
				$menu->{'playall'} => 1;
				if(defined($item->{'itemAttributes'}->{'album'}) && defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0])) {
					$menu->{'line1'} = $item->{'text'};
					$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'}." - ".$item->{'itemAttributes'}->{'album'}->{'name'};
				}elsif(defined($item->{'itemAttributes'}->{'mainArtists'}) && defined($item->{'itemAttributes'}->{'mainArtists'}[0])) {
					$menu->{'line1'} = $item->{'text'};
					$menu->{'line2'} = $item->{'itemAttributes'}->{'mainArtists'}[0]->{'name'};
				}elsif(defined($item->{'itemAttributes'}->{'album'})) {
					$menu->{'line1'} = $item->{'text'};
					$menu->{'line2'} = $item->{'itemAttributes'}->{'album'}->{'name'};
				}
					
			}
			push @menus,$menu;
		}
		$log->debug("Got ".scalar(@menus)." items");
	}else {
		$log->warn("Error: ".Dumper($jsonResponse));
	}
	if(scalar(@menus)>0) {
		my $resultItems = sliceResult(\@menus,$args,0);
		if(defined($totalItems)) {
			$log->debug("Returning: ".scalar(@$resultItems). " items of ".$totalItems);
			$cb->({items => $resultItems, total => $totalItems, offset => getOffset($args)});
		}else {
			$log->debug("Returning: ".scalar(@$resultItems). " items");
			$cb->({items => $resultItems, offset => getOffset($args)});
		}
	}else {
		$cb->({items => [{
			name => cstring($client, 'PLUGIN_ICKSTREAM_BROWSE_NO_ITEMS'),
			type => 'textarea',
              }]});
	}
}

sub getParameterFromParent {
	my $parameter = shift;
	my $parent = shift;
	
	if(defined($parent->{'id'})) {
		if($parameter eq $parent->{'type'}.'Id') {
			return $parent->{'id'};
		}elsif(defined($parent->{'parent'})) {
			return getParameterFromParent($parameter,$parent->{'parent'});
		}
	}elsif(defined($parent->{'parent'})) {
		return getParameterFromParent($parameter,$parent->{'parent'});
	}
	return undef;
}

1;
