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
		'getProtocolDescription' => \&getProtocolDescription,
        'findTopLevelItems'        => \&findTopLevelItems,
        'findItems'        => \&findItems,
);

sub initPlugin {
	my $class = shift;

	my $self = $class->SUPER::initPlugin(@_);

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

        # Parse the input
        # Convert JSON to Perl
        # FIXME: JSON 2.0 accepts multiple requests ? How do we parse that efficiently?
        my $procedure = from_json($input);

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

        # we must have a method
        my $method = $procedure->{'method'};

        if (!$method) {

                $log->debug("Request has no method => closing connection");

                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }

        # figure out the method wanted
        my $funcPtr = $methods{$method};
        
        if (!$funcPtr) {

				# Ignoring messages not for our usage
				
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
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

        # create a hash to store our context
        my $context = {};
        $context->{'httpClient'} = $httpClient;
        $context->{'httpResponse'} = $httpResponse;
        $context->{'procedure'} = $procedure;
        

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
                if ( $log->is_error ) {
                        my $funcName = Slim::Utils::PerlRunTime::realNameForCodeRef($funcPtr);
                        $log->error("While trying to run function coderef [$funcName]: [$@]");
                        main::DEBUGLOG && $log->error( "JSON parsed procedure: " . Data::Dump::dump($procedure) );
                }
                Slim::Web::HTTP::closeHTTPSocket($httpClient);
                return;
        }
}

# genreateJSONResponse

sub generateJSONResponse {
        my $context = shift;
        my $result = shift;

        if($log->is_debug) { $log->debug("generateJSONResponse()"); }

        # create an object for the response
        my $response = {};
        
        # add ID if we have it
        if (defined(my $id = $context->{'procedure'}->{'id'})) {
                $response->{'id'} = $id;
        }
        # add result
        $response->{'result'} = $result;

        Slim::Web::JSONRPC::writeResponse($context, $response);
}

sub getServiceId {
	return uc($serverPrefs->get('server_uuid'));
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
		'items_loop' => \@resultItems
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
			'items_loop' => $items
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
		'items_loop' => \@items
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

sub findAlbums {
	my $reqParams = shift;
	my $offset = shift;
	my $count = shift;
	
	my $serverPrefix = getServerId();

	my @items = ();
	
	my @whereDirectives = ();
	my @whereDirectiveValues = ();
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
	if(scalar(@whereDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective = join(' AND ', @whereDirectives);
		$whereDirective =~ s/\%/\%\%/g;
		$sql .= $whereDirective . ' ';
	}
	$sql .= "GROUP BY albums.id ORDER BY $order_by";
	if(defined($count)) {
		$sql .= " LIMIT $offset, $count";
	}
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$sth->execute(@whereDirectiveValues);
	
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
				'id' => "album:$albumId",
				'name' => $albumTitle,
				'mainartists' => \@artists
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

	$sql .= "GROUP BY contributors.id ORDER BY $order_by";
	if(defined($count)) {
		$sql .= " LIMIT $offset, $count";
	}
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$sth->execute();
	
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
				'id' => "artist:$artistId",
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

sub findTracks {
	my $reqParams = shift;
	my $offset = shift;
	my $count = shift;
	
	my $serverPrefix = getServerId();

	my @items = ();
	
	my @whereDirectives = ();
	my @whereDirectiveValues = ();
	my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year FROM tracks JOIN albums on albums.id=tracks.album ';
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

	if(scalar(@whereDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective = join(' AND ', @whereDirectives);
		$whereDirective =~ s/\%/\%\%/g;
		$sql .= $whereDirective . ' ';
	}
	$sql .= "GROUP BY tracks.id ORDER BY $order_by";
	if(defined($count)) {
		$sql .= " LIMIT $offset, $count";
	}
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$sth->execute(@whereDirectiveValues);
	
	my $trackId;
	my $trackUrl;
	my $trackMd5Url;
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
	$sth->bind_col(4,\$trackNumber);
	$sth->bind_col(5,\$trackTitle);
	$sth->bind_col(6,\$trackSortTitle);
	$sth->bind_col(7,\$trackCover);
	$sth->bind_col(8,\$trackYear);
	$sth->bind_col(9,\$trackDisc);
	$sth->bind_col(10,\$trackDuration);
	$sth->bind_col(11,\$trackFormat);
	$sth->bind_col(12,\$albumId);
	$sth->bind_col(13,\$albumTitle);

	my $serverAddress = Slim::Utils::Network::serverAddr();
	($serverAddress) = split /:/, $serverAddress;
	
	$serverAddress .= ":" . $serverPrefs->get('httpport');
	
	while ($sth->fetch) {
		utf8::decode($trackSortTitle);
		utf8::decode($trackTitle);
		utf8::decode($albumTitle);
			
		my $sortText = (defined($trackDisc)?($trackDisc<10?"0".$trackDisc."-":$trackDisc."-"):"").(defined($trackNumber)?($trackNumber<10?"0".$trackNumber:$trackNumber):"").". ".$trackSortTitle;
		my $displayText = (defined($trackDisc)?$trackDisc."-":"").(defined($trackNumber)?$trackNumber:"").". ".$trackTitle;
		if(!exists($reqParams->{'albumId'})) {
			$sortText = $trackSortTitle;
			$displayText = $trackTitle;
		}
		my @streamingRefs = ({
			'format' => Slim::Music::Info::mimeType($trackUrl),
			'url' => "service://".getServiceId()."/plugins/IckStreamPlugin/music/$trackMd5Url/download"
		});
		my $item = {
			'id' => "$serverPrefix:track:$trackMd5Url",
			'text' => $displayText,
			'sortText' => $sortText,
			'type' => "track",
			'streamingRefs' => \@streamingRefs,
			'itemAttributes' => {
				'id' => "track:$trackMd5Url",
				'name' => $trackTitle,
				'album' => {
					'id' => "album:$albumId",
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
