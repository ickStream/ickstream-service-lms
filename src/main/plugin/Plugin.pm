#   Copyright (C) 2012 Erland Isaksson (erland@isaksson.info)
#   All rights reserved.
package Plugins::IckStreamPlugin::Plugin;

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

use Plugins::IckStreamPlugin::Server;

my $log = Slim::Utils::Log->addLogCategory({
	'category'     => 'plugin.ickstream',
	'defaultLevel' => 'WARN',
	'description'  => 'PLUGIN_ICKSTREAM',
});

my $prefs = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');

$prefs->init({ port => '9997' });

# this holds a context for each connection, to enable asynchronous commands as well
# as subscriptions.
our %contexts = ();

# this array provides a function for each supported JSON method
my %methods = (
		'getServiceInformation'	=> \&getServiceInformation,
		'getManagementProtocolDescription' => \&getManagementProtocolDescription,
		'getProtocolDescription' => \&getProtocolDescription,
        'findTopLevelItems'        => \&findTopLevelItems,
        'findItems'        => \&findItems,
        'getItem'	=> \&getItem,
);

sub initPlugin {
	my $class = shift;

	my $self = $class->SUPER::initPlugin(@_);

	Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + 3, \&startServer,$class);
}


sub startServer {
	my $class = shift;
	
	Plugins::IckStreamPlugin::Server->start($class);
}

sub shutdownPlugin {
	Plugins::IckStreamPlugin::Server->stop;
}

sub getDisplayName { 'PLUGIN_ICKSTREAM' }

my $jars;

sub jars {
	my ($class, $re) = @_;

	$jars || do {

		my $basedir = $class->_pluginDataFor('basedir');
		my @dirs = ($basedir);
		
		for my $dir (@dirs) {
			for my $file (Slim::Utils::Misc::readDirectory($dir, 'jar')) {
				my $path = catdir($dir, $file);{ 
					if (-f $path && -r $path) {
						$jars->{ $file } = $path;
					}
				}
			}
		}
	};

	for my $key (keys %$jars) {
		if ($key =~ $re) {
			return ($key, $jars->{$key});
		}
	}
}

sub webPages {
	my $class = shift;

	Slim::Web::Pages->addRawFunction('IckStreamPlugin/jsonrpc', \&handleJSONRPC);
	Slim::Web::Pages->addRawFunction('IckStreamPlugin/music/.*', \&handleStream);
	Slim::Web::HTTP::addCloseHandler(\&handleClose);

	return unless main::WEBUI;

}

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

sub handleStream {
	my ($httpClient, $httpResponse) = @_;
	my $uri = $httpResponse->request()->uri;
	if($uri =~ /\/plugins\/IckStreamPlugin\/music\/([^\/]+)\/download/) {
		my $trackId = $1;
		my $sql = "SELECT id from TRACKS where urlmd5=?";
		my $dbh = Slim::Schema->dbh;
		my $sth = $dbh->prepare_cached($sql);
		$log->debug("Executing $sql");
		my @params = ($trackId);
		$sth->execute(@params);
		my $id;
		$sth->bind_col(1,\$id);
		if ($sth->fetch) {
			$log->debug("Redirect to /music/$id/download");
			my $serverAddress = Slim::Utils::Network::serverAddr();
			($serverAddress) = split /:/, $serverAddress;
			$serverAddress .= ":" . $serverPrefs->get('httpport');
		    $httpResponse->code(RC_MOVED_TEMPORARILY);
		    $httpResponse->header('Location' => "http://".$serverAddress."/music/$id/download");
			$httpClient->send_response($httpResponse);
		    Slim::Web::HTTP::closeHTTPSocket($httpClient);
		    return;
		}
	}
	$httpResponse->code(RC_NOT_FOUND);
    $httpResponse->content_type('text/html');
    $httpResponse->header('Connection' => 'close');
    my $params = {
    	'path' => $uri
    };
    $httpResponse->content_ref(Slim::Web::HTTP::filltemplatefile('html/errors/404.html', $params));
	$httpClient->send_response($httpResponse);
    Slim::Web::HTTP::closeHTTPSocket($httpClient);
    return;
}

sub handleJSONRPC {
	my ($httpClient, $httpResponse) = @_;

        # make sure we're connected
        if (!$httpClient->connected()) {
                $log->warn("Aborting, client not connected: $httpClient");
                return;
        }

        # cancel any previous subscription on this connection
        # we must have a context defined and a subscription defined
        if (defined($contexts{$httpClient}) && 
                Slim::Control::Request::unregisterAutoExecute($httpClient)) {
        
                # we want to send a last chunk to close the connection as per HTTP...
                # a subscription is essentially a never ending response: we're receiving here
                # a new request (aka pipelining) so we want to be nice and close the previous response
                
                # we cannot have a subscription if this is not a long lasting, keep-open, chunked connection.
                
                Slim::Web::HTTP::addHTTPLastChunk($httpClient, 0);
        }

        # get the request data (POST for JSON 2.0)
        my $input = $httpResponse->request()->content();

        if (!$input) {

                # No data
                # JSON 2.0 => close connection
                $log->warn("No POST data found => closing connection");

                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }

        $log->is_info && $log->info("POST data: [$input]");

        # create a hash to store our context
        my $context = {};
        $context->{'httpClient'} = $httpClient;
        $context->{'httpResponse'} = $httpResponse;

		my $procedure = undef;
		eval {
	        # Parse the input
	        # Convert JSON to Perl
	        # FIXME: JSON 2.0 accepts multiple requests ? How do we parse that efficiently?
	        $procedure = from_json($input);
		};
        if ($@) {
				generateJSONResponse($context, undef, {
					'code' => -32700,
					'message' => 'Invalid JSON'
				});
				return;
        }

        # Validate the procedure
        # We must get a JSON object, i.e. a hash
        if (ref($procedure) ne 'HASH') {
                
                $log->warn("Cannot parse POST data into Perl hash => closing connection");
                
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }
        
        if ( main::DEBUGLOG && $log->is_debug ) {
                $log->debug( "JSON parsed procedure: " . Data::Dump::dump($procedure) );
        }

        $context->{'procedure'} = $procedure;
		
		# ignore notifications (which don't have an id)
		if (!defined($procedure->{'id'})) {
				$log->debug("Ignoring notification: ".$procedure->{'method'});
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
		}

		# ignore errors, just log them
		if (defined($procedure->{'error'})) {
				$log->warn("JSON error on id=".$procedure->{'id'}.": ".$procedure->{'error'}->{'code'}.":".$procedure->{'error'}->{'code'}.(defined($procedure->{'error'}->{'data'})?"(".$procedure->{'error'}->{'data'}.")":""));
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
		}

        # we must have a method
        my $method = $procedure->{'method'};

        if (!$method) {
				generateJSONResponse($context, undef, {
					'code' => -32601,
					'message' => 'Method not found',
					'data' => $method
				});
				return;
        }

        # figure out the method wanted
        my $funcPtr = $methods{$method};
        
        if (!$funcPtr) {

				generateJSONResponse($context, undef, {
					'code' => -32601,
					'message' => 'Method not found',
					'data' => $method
				});
				return;
                
        } elsif (ref($funcPtr) ne 'CODE') {
                # return internal server error
                $log->error("Procedure $method refers to non CODE ??? => closing connection");
                
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }
        

        # parse the parameters
        my $params = $procedure->{'params'};

        if (defined($params) && ref($params) ne 'HASH') {
                
                # error, params is an array or an object
                $log->warn("Procedure $method has params not HASH => closing connection");
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }        

        # Detect the language the client wants content returned in
        if ( my $lang = $httpResponse->request->header('Accept-Language') ) {
                my @parts = split(/[,-]/, $lang);
                $context->{lang} = uc $parts[0] if $parts[0];
        }

        if ( my $ua = ( $httpResponse->request->header('X-User-Agent') || $httpResponse->request->header('User-Agent') ) ) {
                $context->{ua} = $ua;
        }

        # Check our operational mode using our X-Jive header
        # We must be delaing with a 1.1 client because X-Jive uses chunked transfers
        # We must not be closing the connection
        if (defined(my $xjive = $httpResponse->request()->header('X-Jive')) &&
                $httpClient->proto_ge('1.1') &&
                $httpResponse->header('Connection') !~ /close/i) {
        
                main::INFOLOG && $log->info("Operating in x-jive mode for procedure $method and client $httpClient");
                $context->{'x-jive'} = 1;
                $httpResponse->header('X-Jive' => 'Jive')
        }
                
        # remember we need to send headers. We'll reset this once sent.
        $context->{'sendheaders'} = 1;
        
        # store our context. It'll get erased by the callback in HTTP.pm through handleClose
        $contexts{$httpClient} = $context;

        # jump to the code handling desired method. It is responsible to send a suitable output
        eval { &{$funcPtr}($context); };

        if ($@) {
                my $funcName = Slim::Utils::PerlRunTime::realNameForCodeRef($funcPtr);
                $log->error("While trying to run function coderef [$funcName]: [$@]");
                main::DEBUGLOG && $log->error( "JSON parsed procedure: " . Data::Dump::dump($procedure) );

				generateJSONResponse($context, undef, {
					'code' => -32001,
					'message' => 'Error when executing $funcName',
					'data' => $@
				});
				return;
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

sub getServiceId {
	return uc($prefs->get('uuid'));
}

sub getServerId {
	return getServiceId().":lms";
}

sub getProtocolDescription {
	my $context = shift;

	my @contexts = ();

	my $artistRequests = {
					'type' => 'artist',
					'parameters' => [
						['contextId','type']
					],
				};
	my $albumRequests = {
					'type' => 'album',
					'parameters' => [
						['contextId','type'],
						['contextId','type','artistId']
					],
				};

	my $trackRequests = {
					'type' => 'track',
					'parameters' => [
						['contextId','type','albumId'],
						['contextId','type','artistId'],
						['contextId','type','artistId','albumId']
					]
				};
	
	my $myMusicContext = {
			'contextId' => 'myMusic',
			'name' => 'My Music',
			'supportedRequests' => [
				$artistRequests,
				$albumRequests,
				$trackRequests
			]
		};
	
	push @contexts,$myMusicContext;

	my $artistSearchRequests = {
		'type' => 'artist',
		'parameters' => [
			['contextId','type','search']
		]
	};
	my $albumSearchRequests = {
		'type' => 'album',
		'parameters' => [
			['contextId','type','search'],
			['contextId','type','artistId']
		]
	};
	my $trackSearchRequests = {
		'type' => 'track',
		'parameters' => [
			['contextId','type','search'],
			['contextId','type','albumId'],
			['contextId','type','artistId'],
			['contextId','type','artistId','albumId']
		]
	};

	my $allMusicContext = {
			'contextId' => 'allMusic',
			'name' => 'All Music',
			'supportedRequests' => [
				$artistSearchRequests,
				$albumSearchRequests,
				$trackSearchRequests
			]
		};
	
	push @contexts,$allMusicContext;

    # get the JSON-RPC params
    my $reqParams = $context->{'procedure'}->{'params'};
	if ( $log->is_debug ) {
	        $log->debug( "getProtocolDescription(" . Data::Dump::dump($reqParams) . ")" );
	}

	my $count = $reqParams->{'count'} if exists($reqParams->{'count'});
	my $offset = $reqParams->{'offset'} || 0;
	if(!defined($count)) {
		$count = scalar(@contexts);
	}

	my @resultItems = ();
	my $i = 0;
	for my $context (@contexts) {
		if($i>=$offset && scalar(@resultItems)<$count) {
			push @resultItems,$context;
		}
		$i++;
	}

	my $result = {
		'offset' => $offset,
		'count' => scalar(@resultItems),
		'countAll' => scalar(@contexts),
		'items' => \@resultItems
	};
	# the request was successful and is not async, send results back to caller!
	requestWrite($result, $context->{'httpClient'}, $context);

}

sub getManagementProtocolDescription {
	my $context = shift;

	my @contexts = ();

    # get the JSON-RPC params
    my $reqParams = $context->{'procedure'}->{'params'};
	if ( $log->is_debug ) {
	        $log->debug( "getProtocolDescription(" . Data::Dump::dump($reqParams) . ")" );
	}

	my $count = $reqParams->{'count'} if exists($reqParams->{'count'});
	my $offset = $reqParams->{'offset'} || 0;
	if(!defined($count)) {
		$count = scalar(@contexts);
	}

	my @resultItems = ();
	my $i = 0;
	for my $context (@contexts) {
		if($i>=$offset && scalar(@resultItems)<$count) {
			push @resultItems,$context;
		}
		$i++;
	}

	my $result = {
		'offset' => $offset,
		'count' => scalar(@resultItems),
		'countAll' => scalar(@contexts),
		'items' => \@resultItems
	};
	# the request was successful and is not async, send results back to caller!
	requestWrite($result, $context->{'httpClient'}, $context);

}

sub getTopLevelItems {
	my $serverPrefix = getServerId();
	my @topLevelItems = (
		{
			'id' => "$serverPrefix:myMusic",
			'text' => 'My Library',
			'type' => 'menu'
		},
		{
			'id' => "$serverPrefix:myMusic/artists",
			'text' => 'Artists',
			'type' => 'menu',
			'parentNode' => "$serverPrefix:myMusic"
		},
		{
			'id' => "$serverPrefix:myMusic/albums",
			'text' => 'Albums',
			'type' => 'menu',
			'parentNode' => "$serverPrefix:myMusic"
		}
	);
	return \@topLevelItems;
}

sub getItem {
	my $context = shift;

	eval {
	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
	
		if ( $log->is_debug ) {
		        $log->debug( "getItem(" . Data::Dump::dump($reqParams) . ")" );
		}

		my $item = undef;
		
		my $serverPrefix = getServerId();
		
		if($reqParams->{'itemId'} =~ /$serverPrefix/) {
			if($reqParams->{'itemId'} =~ /^.*\:artist\:(.*)$/) {
				$item = getArtist($1);
			}elsif($reqParams->{'itemId'} =~ /^.*\:album\:(.*)$/) {
				$item = getAlbum($1);
			}elsif($reqParams->{'itemId'} =~ /.*\:track\:(.*)$/) {
				$item = getTrack($1);
			}
		}
	
		# the request was successful and is not async, send results back to caller!
		requestWrite($item, $context->{'httpClient'}, $context);
	};
    if ($@) {
		$log->error("An error occurred $@");
    }
}

sub findItems {
	my $context = shift;

	eval {
	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
	
		if ( $log->is_debug ) {
		        $log->debug( "findItems(" . Data::Dump::dump($reqParams) . ")" );
		}
	
		my $count = $reqParams->{'count'} if exists($reqParams->{'count'});
		my $offset = $reqParams->{'offset'} || 0;
		
		my $items = undef;
		if(exists($reqParams->{'type'}) && $reqParams->{'type'} eq 'album') {
			$items = findAlbums($reqParams,$offset,$count);
		} elsif(exists($reqParams->{'type'}) && $reqParams->{'type'} eq 'artist') {
			$items = findArtists($reqParams,$offset,$count);
		} elsif(exists($reqParams->{'type'}) && $reqParams->{'type'} eq 'track') {
			$items = findTracks($reqParams,$offset,$count);
		}
			
		my $result = {
			'offset' => $offset,
			'count' => scalar(@$items),
			'expirationTimestamp' => time()+24*3600,
			'items' => $items
		};
	
		# the request was successful and is not async, send results back to caller!
		requestWrite($result, $context->{'httpClient'}, $context);
	};
    if ($@) {
		$log->error("An error occurred $@");
    }
}

sub getServiceInformation {
	my $context = shift;
	if ( $log->is_debug ) {
	        $log->debug( "getServiceInformation()" );
	}
	my $serverName = $serverPrefs->get('libraryname');
	if(!defined($serverName) || $serverName eq '') {
		$serverName = Slim::Utils::Network::hostName();
	}

	my $serverAddress = Slim::Utils::Network::serverAddr();
	($serverAddress) = split /:/, $serverAddress;
	
	$serverAddress .= ":" . $serverPrefs->get('httpport');

	my $result = {
		'id' => getServiceId(),
		'name' => $serverName,
		'type' => 'content',
		'serviceUrl' => 'http://'.$serverAddress
	};
	# the request was successful and is not async, send results back to caller!
	requestWrite($result, $context->{'httpClient'}, $context);
}

sub findTopLevelItems {
	my $context = shift;

    # get the JSON-RPC params
    my $reqParams = $context->{'procedure'}->{'params'};

	if ( $log->is_debug ) {
	        $log->debug( "findTopLevelItems(" . Data::Dump::dump($reqParams) . ")" );
	}

	my $count = $reqParams->{'count'} if exists($reqParams->{'count'});
	my $offset = $reqParams->{'offset'} || 0;
	
	my @items = ();
	
	my $i = 0;
	my $topLevelItems = getTopLevelItems();
	for my $item (@$topLevelItems) {
		if($i>=$offset && (!defined($count) || scalar(@items)<$count)) {
			push @items,$item;
		}
		$i++;
	}
	
	my $result = {
		'offset' => $offset,
		'count' => scalar(@items),
		'countAll' => scalar(@$topLevelItems),
		'items' => \@items
	};

	# the request was successful and is not async, send results back to caller!
	requestWrite($result, $context->{'httpClient'}, $context);
}

# requestWrite( $request $httpClient, $context)
# Writes a request downstream. $httpClient and $context are retrieved if not
# provided (from the request->connectionID and from the contexts array, respectively)
sub requestWrite {
        my $result = shift;
        my $httpClient = shift;
        my $context = shift;

        if($log->is_debug) { $log->debug("requestWrite()"); }
        if($log->is_debug) { $log->debug(Data::Dump::dump($result)); }

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
        generateJSONResponse($context, $result);
}

sub getAlbum {
	my $albumId = shift;

	my $sql = 'SELECT albums.id,albums.title,albums.titlesort,albums.artwork,albums.disc,albums.year,contributors.id,contributors.name FROM albums ';
	$sql .= 'JOIN contributors on contributors.id = albums.contributor ';
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	my $order_by = "albums.titlesort $collate, albums.disc";

	my @whereDirectives = ();
	my @whereDirectiveValues = ();

	push @whereDirectives,'albums.id=?';
	push @whereDirectiveValues,$albumId;
	
	if(scalar(@whereDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective;
		if(scalar(@whereDirectives)>0) {
			$whereDirective = join(' AND ', @whereDirectives);
		}
		$sql .= $whereDirective . ' ';
	}
	$sql .= "GROUP BY albums.id ORDER BY $order_by";
	$sql .= " LIMIT 0, 1";

	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$log->debug("Using values: ".join(',',@whereDirectiveValues));
	$sth->execute(@whereDirectiveValues);

	my $items = processAlbumResult($sth,$order_by);
	my $item = pop @$items;
	return $item;
}

sub findAlbums {
	my $reqParams = shift;
	my $offset = shift;
	my $count = shift;
	
	my @items = ();
	
	my @whereDirectives = ();
	my @whereDirectiveValues = ();
	my @whereSearchDirectives = ();
	my @whereSearchDirectiveValues = ();
	my $sql = 'SELECT albums.id,albums.title,albums.titlesort,albums.artwork,albums.disc,albums.year,contributors.id,contributors.name FROM albums ';
	my $order_by = undef;
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	if(exists($reqParams->{'artistId'})) {
		$sql .= 'JOIN contributors on contributors.id = albums.contributor ';

		$sql .= 'JOIN contributor_album ON contributor_album.album = albums.id ';
		push @whereDirectives, 'contributor_album.contributor=?';
		push @whereDirectiveValues, getInternalId($reqParams->{'artistId'});
		$order_by = "albums.year desc, albums.titlesort $collate, albums.disc";
	}else {
		$sql .= 'JOIN contributors on contributors.id = albums.contributor ';
		$order_by = "albums.titlesort $collate, albums.disc";
	}
	if(exists($reqParams->{'search'})) {
		my $searchStrings = Slim::Utils::Text::searchStringSplit($reqParams->{'search'});
		if( ref $searchStrings->[0] eq 'ARRAY') {
			for my $search (@{$searchStrings->[0]}) {
				push @whereSearchDirectives,'albums.titlesearch LIKE ?';
				push @whereSearchDirectiveValues,$search;
			}
		}else {
				push @whereSearchDirectives,'albums.titlesearch LIKE ?';
				push @whereSearchDirectiveValues,$searchStrings;
		}
	}
	
	if(scalar(@whereDirectives)>0 || scalar(@whereSearchDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective;
		if(scalar(@whereDirectives)>0) {
			$whereDirective = join(' AND ', @whereDirectives);
			if(scalar(@whereSearchDirectives)>0) {
				$whereDirective .= ' AND ('.join(' OR ',@whereSearchDirectives).')';
			}
		}elsif(scalar(@whereSearchDirectives)>0) {
			$whereDirective .= join(' OR ',@whereSearchDirectives);
		}
		$whereDirective =~ s/\%/\%\%/g;
		push @whereDirectiveValues,@whereSearchDirectiveValues;
		$sql .= $whereDirective . ' ';
	}
	$sql .= "GROUP BY albums.id ORDER BY $order_by";
	if(defined($count)) {
		$sql .= " LIMIT $offset, $count";
	}
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$log->debug("Using values: ".join(',',@whereDirectiveValues));
	$sth->execute(@whereDirectiveValues);

	return processAlbumResult($sth,$order_by);
}

sub processAlbumResult {
	my $sth = shift;
	my $order_by = shift;
		
	my $serverPrefix = getServerId();
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();

	my @items = ();
	
	my $albumId;
	my $albumTitle;
	my $albumSortTitle;
	my $albumCover;
	my $albumDisc;
	my $albumYear;
	my $artistId;
	my $artistName;
	
	$sth->bind_col(1,\$albumId);
	$sth->bind_col(2,\$albumTitle);
	$sth->bind_col(3,\$albumSortTitle);
	$sth->bind_col(4,\$albumCover);
	$sth->bind_col(5,\$albumDisc);
	$sth->bind_col(6,\$albumYear);
	$sth->bind_col(7,\$artistId);
	$sth->bind_col(8,\$artistName);
	
	while ($sth->fetch) {
		utf8::decode($albumTitle);
		utf8::decode($albumSortTitle);
		utf8::decode($artistName);
		
		my @artists = ({
			'id' => "$serverPrefix:artist:$artistId",
			'name' => $artistName
		});
		
		my $item = {
			'id' => "$serverPrefix:album:$albumId",
			'text' => $albumTitle,
			'sortText' => $albumSortTitle,
			'type' => "album",
			'itemAttributes' => {
				'id' => "$serverPrefix:album:$albumId",
				'name' => $albumTitle,
				'mainArtists' => \@artists
			}
		};
		
		if($order_by eq "albums.titlesort $collate, albums.disc") {
			$item->{'sortText'} = $albumSortTitle." ".(defined($albumDisc)?$albumDisc:"");
		}elsif($order_by eq "albums.year desc, albums.titlesort $collate, albums.disc") {
			$item->{'sortText'} = $albumYear." ".$albumSortTitle." ".(defined($albumDisc)?$albumDisc:"");
		}
		
		if(defined($albumCover)) {
			$item->{'image'} = "service://".getServiceId()."/music/$albumCover/cover";
		}

		if(defined($albumYear) && $albumYear>0) {
			$item->{'itemAttributes'}->{'year'} = $albumYear;
		}
		
		push @items,$item;
	}
	return \@items;		
}

sub getArtist {
	my $artistId = shift;

	my $serverPrefix = getServerId();
	my $sql = 'SELECT contributors.id,contributors.name,contributors.namesort FROM contributors JOIN albums ON albums.contributor=contributors.id ';
	my $order_by = undef;
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	$order_by = "contributors.namesort $collate";

	my @whereDirectives = ();
	my @whereDirectiveValues = ();
	push @whereDirectives,'contributors.id=?';
	push @whereDirectiveValues,$artistId;
	
	if(scalar(@whereDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective;
		if(scalar(@whereDirectives)>0) {
			$whereDirective = join(' AND ', @whereDirectives);
		}
		$sql .= $whereDirective . ' ';
	}

	$sql .= "GROUP BY contributors.id ORDER BY $order_by";
	$sql .= " LIMIT 0, 1";

	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$log->debug("Using values: ".join(',',@whereDirectiveValues));
	$sth->execute(@whereDirectiveValues);

	my $items = processArtistResult($sth);
	my $item = pop @$items;
	return $item;
}

sub findArtists {
	my $reqParams = shift;
	my $offset = shift;
	my $count = shift;
	
	my $serverPrefix = getServerId();

	my @items = ();
	
	my $sql = 'SELECT contributors.id,contributors.name,contributors.namesort FROM contributors JOIN albums ON albums.contributor=contributors.id ';
	my $order_by = undef;
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	$order_by = "contributors.namesort $collate";

	my @whereDirectives = ();
	my @whereDirectiveValues = ();
	my @whereSearchDirectives = ();
	my @whereSearchDirectiveValues = ();
	if(exists($reqParams->{'search'})) {
		my $searchStrings = Slim::Utils::Text::searchStringSplit($reqParams->{'search'});
		if( ref $searchStrings->[0] eq 'ARRAY') {
			for my $search (@{$searchStrings->[0]}) {
				push @whereSearchDirectives,'contributors.namesearch LIKE ?';
				push @whereSearchDirectiveValues,$search;
			}
		}else {
				push @whereSearchDirectives,'contributors.namesearch LIKE ?';
				push @whereSearchDirectiveValues,$searchStrings;
		}
	}

	if(scalar(@whereDirectives)>0 || scalar(@whereSearchDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective;
		if(scalar(@whereDirectives)>0) {
			$whereDirective = join(' AND ', @whereDirectives);
			if(scalar(@whereSearchDirectives)>0) {
				$whereDirective .= ' AND ('.join(' OR ',@whereSearchDirectives).')';
			}
		}elsif(scalar(@whereSearchDirectives)>0) {
			$whereDirective .= join(' OR ',@whereSearchDirectives);
		}
		$whereDirective =~ s/\%/\%\%/g;
		push @whereDirectiveValues,@whereSearchDirectiveValues;
		$sql .= $whereDirective . ' ';
	}

	$sql .= "GROUP BY contributors.id ORDER BY $order_by";
	if(defined($count)) {
		$sql .= " LIMIT $offset, $count";
	}
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	if(scalar(@whereDirectiveValues)>0) {
		$log->debug("Using values: ".join(',',@whereDirectiveValues));
		$sth->execute(@whereDirectiveValues);
	}else {
		$sth->execute();
	}
	return processArtistResult($sth);	
}

sub processArtistResult {
	my $sth = shift;
	
	my $serverPrefix = getServerId();

	my @items = ();
	
	my $artistId;
	my $artistName;
	my $artistSortName;
	
	$sth->bind_col(1,\$artistId);
	$sth->bind_col(2,\$artistName);
	$sth->bind_col(3,\$artistSortName);
	
	while ($sth->fetch) {
		utf8::decode($artistName);
		utf8::decode($artistSortName);
		
		my $item = {
			'id' => "$serverPrefix:artist:$artistId",
			'text' => $artistName,
			'sortText' => $artistSortName,
			'type' => "artist",
			'itemAttributes' => {
				'id' => "$serverPrefix:artist:$artistId",
				'name' => $artistName
			}
		};
		
		push @items,$item;
	}
	return \@items;		
}

sub getInternalId {
	my $globalId = shift;
	
	if($globalId =~ /^[^:]*:lms:[^:]*:(.*)$/) {
		return $1;
	}else {
		return undef;
	}
}

sub getTrack {
	my $trackId = shift;
	
	my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year FROM tracks JOIN albums on albums.id=tracks.album ';
	my $order_by = "tracks.titlesort";

	my @whereDirectives = ();
	my @whereDirectiveValues = ();
	
	push @whereDirectives, 'tracks.urlmd5=?';
	push @whereDirectiveValues, $trackId;

	if(scalar(@whereDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective;
		if(scalar(@whereDirectives)>0) {
			$whereDirective = join(' AND ', @whereDirectives);
		}
		$sql .= $whereDirective . ' ';
	}
	$sql .= "GROUP BY tracks.id ORDER BY $order_by";
	$sql .= " LIMIT 0, 1";

	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$log->debug("Using values: ".join(',',@whereDirectiveValues));
	$sth->execute(@whereDirectiveValues);

	my $items = processTrackResult($sth,undef);
	my $item = pop @$items;
	return $item;
}

sub findTracks {
	my $reqParams = shift;
	my $offset = shift;
	my $count = shift;
	
	my $serverPrefix = getServerId();

	my @items = ();
	
	my @whereDirectives = ();
	my @whereDirectiveValues = ();
	my @whereSearchDirectives = ();
	my @whereSearchDirectiveValues = ();
	my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year FROM tracks JOIN albums on albums.id=tracks.album ';
	my $order_by = "tracks.disc,tracks.tracknum,tracks.titlesort";
	if(exists($reqParams->{'artistId'})) {
		my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
		$sql .= 'JOIN contributor_track ON contributor_track.track = tracks.id ';
		push @whereDirectives, 'contributor_track.contributor=?';
		push @whereDirectiveValues, getInternalId($reqParams->{'artistId'});
	}
	if(exists($reqParams->{'albumId'})) {
		push @whereDirectives, 'tracks.album=?';
		push @whereDirectiveValues, getInternalId($reqParams->{'albumId'});
	}else {
		$order_by = "tracks.titlesort";
	}
	if(exists($reqParams->{'search'})) {
		my $searchStrings = Slim::Utils::Text::searchStringSplit($reqParams->{'search'});
		if( ref $searchStrings->[0] eq 'ARRAY') {
			for my $search (@{$searchStrings->[0]}) {
				push @whereSearchDirectives,'tracks.titlesearch LIKE ?';
				push @whereSearchDirectiveValues,$search;
			}
		}else {
				push @whereSearchDirectives,'tracks.titlesearch LIKE ?';
				push @whereSearchDirectiveValues,$searchStrings;
		}
	}

	if(scalar(@whereDirectives)>0 || scalar(@whereSearchDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective;
		if(scalar(@whereDirectives)>0) {
			$whereDirective = join(' AND ', @whereDirectives);
			if(scalar(@whereSearchDirectives)>0) {
				$whereDirective .= ' AND ('.join(' OR ',@whereSearchDirectives).')';
			}
		}elsif(scalar(@whereSearchDirectives)>0) {
			$whereDirective .= join(' OR ',@whereSearchDirectives);
		}
		$whereDirective =~ s/\%/\%\%/g;
		push @whereDirectiveValues,@whereSearchDirectiveValues;
		$sql .= $whereDirective . ' ';
	}
	$sql .= "GROUP BY tracks.id ORDER BY $order_by";
	if(defined($count)) {
		$sql .= " LIMIT $offset, $count";
	}
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$log->debug("Using values: ".join(',',@whereDirectiveValues));
	$sth->execute(@whereDirectiveValues);

	return processTrackResult($sth,$reqParams->{'albumId'});	
}

sub processTrackResult {
	my $sth = shift;
	my $requestedAlbumId = shift;
	
	my $serverPrefix = getServerId();
	my @items = ();

	my $trackId;
	my $trackUrl;
	my $trackMd5Url;
	my $trackSampleRate;
	my $trackSampleSize;
	my $trackChannels;
	my $trackNumber;
	my $trackTitle;
	my $trackSortTitle;
	my $trackCover;
	my $trackYear;
	my $trackDisc;
	my $trackDuration;
	my $trackFormat;
	my $albumId;
	my $albumTitle;
	my $albumYear;
	
	$sth->bind_col(1,\$trackId);
	$sth->bind_col(2,\$trackUrl);
	$sth->bind_col(3,\$trackMd5Url);
	$sth->bind_col(4,\$trackSampleRate);
	$sth->bind_col(5,\$trackSampleSize);
	$sth->bind_col(6,\$trackChannels);
	$sth->bind_col(7,\$trackNumber);
	$sth->bind_col(8,\$trackTitle);
	$sth->bind_col(9,\$trackSortTitle);
	$sth->bind_col(10,\$trackCover);
	$sth->bind_col(11,\$trackYear);
	$sth->bind_col(12,\$trackDisc);
	$sth->bind_col(13,\$trackDuration);
	$sth->bind_col(14,\$trackFormat);
	$sth->bind_col(15,\$albumId);
	$sth->bind_col(16,\$albumTitle);

	my $serverAddress = Slim::Utils::Network::serverAddr();
	($serverAddress) = split /:/, $serverAddress;
	
	$serverAddress .= ":" . $serverPrefs->get('httpport');
	
	while ($sth->fetch) {
		utf8::decode($trackSortTitle);
		utf8::decode($trackTitle);
		utf8::decode($albumTitle);
			
		my $sortText = (defined($trackDisc)?($trackDisc<10?"0".$trackDisc."-":$trackDisc."-"):"").(defined($trackNumber)?($trackNumber<10?"0".$trackNumber:$trackNumber):"").". ".$trackSortTitle;
		my $displayText = (defined($trackDisc)?$trackDisc."-":"").(defined($trackNumber)?$trackNumber:"").". ".$trackTitle;
		if($requestedAlbumId) {
			$sortText = $trackSortTitle;
			$displayText = $trackTitle;
		}
		my $format = Slim::Music::Info::mimeType($trackUrl);
		if($format =~ /flac/) {
			$format = 'audio/flac';
		}elsif($format =~ /m4a/ || $format =~ /mp4/) {
			$format = 'audio/m4a';
		}elsif($format =~ /aac/) {
			$format = 'audio/aac';
		}elsif($format =~ /mp3/ || $format eq 'audio/x-mpeg' || $format eq 'audio/mpeg3' || $format eq 'audio/mpg') {
			$format = 'audio/mpeg';
		}elsif($format =~ /ogg/) {
			$format = 'audio/ogg';
		}elsif($format eq 'audio/L16' || $format eq 'audio/pcm') {
			$format = 'audio/x-pcm';
		}elsif($format eq 'audio/x-ms-wma' || $format eq 'application/vnd.ms.wms-hdr.asfv1' || $format eq 'application/octet-stream' || $format eq 'application/x-mms-framed' || $format eq 'audio/asf') {
			$format = 'audio/x-ms-wma';
		}elsif($format =~ /aiff/) {
			$format = 'audio/x-aiff';
		}elsif($format eq 'audio/x-wav') {
			$format = 'audio/wav';
		}else {
			$format = 'audio/native';
		}
		my @streamingRefs = ({
			'format' => $format,
			'url' => "service://".getServiceId()."/plugins/IckStreamPlugin/music/$trackMd5Url/download"
		});
		if(defined($trackSampleSize) && $trackSampleSize>0) {
			$streamingRefs[0]->{'sampleSize'} = $trackSampleSize;
		}
		if(defined($trackSampleRate) && $trackSampleRate>0) {
			$streamingRefs[0]->{'sampleRate'} = $trackSampleRate;
		}
		if(defined($trackChannels) && $trackChannels>0) {
			$streamingRefs[0]->{'channels'} = $trackChannels;
		}
		my $item = {
			'id' => "$serverPrefix:track:$trackMd5Url",
			'text' => $displayText,
			'sortText' => $sortText,
			'type' => "track",
			'streamingRefs' => \@streamingRefs,
			'itemAttributes' => {
				'id' => "$serverPrefix:track:$trackMd5Url",
				'name' => $trackTitle,
				'album' => {
					'id' => "$serverPrefix:album:$albumId",
					'name' => $albumTitle,
				}
			}
		};
		
		if(defined($trackCover)) {
			$item->{'image'} = "service://".getServiceId()."/music/$trackCover/cover";
		}
		
		if(defined($trackNumber) && $trackNumber>0) {
			$item->{'itemAttributes'}->{'trackNumber'} = $trackNumber;
		}

		if(defined($trackDisc) && $trackDisc>0) {
			$item->{'itemAttributes'}->{'disc'} = $trackDisc;
		}

		if(defined($trackYear) && $trackYear>0) {
			$item->{'itemAttributes'}->{'year'} = $trackYear;
		}

		if(defined($trackDuration) && $trackDuration>0) {
			$item->{'itemAttributes'}->{'duration'} = floor($trackDuration);
		}

		if(defined($albumYear) && $albumYear>0) {
			$item->{'itemAttributes'}->{'album'}->{'year'} = $albumYear;
		}
		
		push @items,$item;
	}
	return \@items;		
}

1;
