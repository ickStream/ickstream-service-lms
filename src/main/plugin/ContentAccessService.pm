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

package Plugins::IckStreamPlugin::ContentAccessService;

use strict;
use warnings;

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

use Plugins::IckStreamPlugin::JsonHandler;

my $log = logger('plugin.ickstream.content');
my $prefs  = preferences('plugin.ickstream');
my $serverPrefs = preferences('server');

my $KEY = undef;

# this array provides a function for each supported JSON method
my %methods = (
		'getServiceInformation'	=> \&getServiceInformation,
		'getProtocolVersions'	=> \&getProtocolVersions,
		'getManagementProtocolDescription' => \&getManagementProtocolDescription,
		'getProtocolDescription' => \&getProtocolDescription,
        'findTopLevelItems'        => \&findTopLevelItems,
        'findItems'        => \&findItems,
        'getNextDynamicPlaylistTracks'        => \&getNextDynamicPlaylistTracks,
        'getItem'	=> \&getItem,
);

sub init {
	my $plugin = shift;
	Slim::Utils::PluginManager->dataForPlugin($plugin)->{'id'};
}

sub getProtocolDescription {
	my $context = shift;

	my @contexts = ();

	my $genreRequests = {
					'type' => 'category',
					'parameters' => [
						['contextId','type']
					],
				};

	my $artistRequests = {
					'type' => 'artist',
					'parameters' => [
						['contextId','type'],
						['contextId','type','categoryId']
					],
				};
	my $albumRequests = {
					'type' => 'album',
					'parameters' => [
						['contextId','type'],
						['contextId','type','artistId'],
						['contextId','type','categoryId'],
						['contextId','type','categoryId','artistId'],
					],
				};

	my $playlistRequests = {
					'type' => 'playlist',
					'parameters' => [
						['contextId','type']
					],
				};

	my $trackRequests = {
					'type' => 'track',
					'parameters' => [
						['contextId','type','playlistId'],
						['contextId','type','albumId'],
						['contextId','type','artistId'],
						['contextId','type','artistId','albumId']
					]
				};
	
	my $myMusicContext = {
			'contextId' => 'myMusic',
			'name' => 'My Music',
			'supportedRequests' => [
				$genreRequests,
				$artistRequests,
				$playlistRequests,
				$albumRequests,
				$trackRequests
			]
		};

	push @contexts,$myMusicContext;
		
	my $folderRequests = {
					'type' => 'menu',
					'parameters' => [
						['contextId','type'],
					]
				};
	my $folderContentRequests = {
					'parameters' => [
						['contextId','menuId']
					]
				};

	my $serverName = $serverPrefs->get('libraryname');
	if(!defined($serverName) || $serverName eq '') {
		$serverName = Slim::Utils::Network::hostName();
	}

	my $myMusicFolderContext = {
			'contextId' => 'myMusicFolder',
			'name' => 'Music Folder ('.$serverName.')',
			'supportedRequests' => [
				$folderRequests,
				$folderContentRequests
			]
		};
	
	push @contexts,$myMusicFolderContext;

	my $myMusicGenresContext = {
			'contextId' => 'myMusicGenres',
			'name' => 'Genres ('.$serverName.')',
			'supportedRequests' => [
				$genreRequests
			]
		};
	
	push @contexts,$myMusicGenresContext;

	my $artistSearchRequests = {
		'type' => 'artist',
		'parameters' => [
			['contextId','type','search'],
			['contextId','type','categoryId']
		]
	};
	my $playlistSearchRequests = {
		'type' => 'playlist',
		'parameters' => [
			['contextId','type','search']
		]
	};
	my $albumSearchRequests = {
		'type' => 'album',
		'parameters' => [
			['contextId','type','search'],
			['contextId','type','artistId'],
			['contextId','type','categoryId'],
			['contextId','type','categoryId','artistId']
		]
	};
	my $trackSearchRequests = {
		'type' => 'track',
		'parameters' => [
			['contextId','type','search'],
			['contextId','type','albumId'],
			['contextId','type','artistId'],
			['contextId','type','artistId','albumId'],
			['contextId','type','categoryId'],
			['contextId','type','categoryId','artistId']
		]
	};

	my $allMusicContext = {
			'contextId' => 'allMusic',
			'name' => 'All Music',
			'supportedRequests' => [
				$playlistSearchRequests,
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
	Plugins::IckStreamPlugin::JsonHandler::requestWrite($result, $context->{'httpClient'}, $context);

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
	Plugins::IckStreamPlugin::JsonHandler::requestWrite($result, $context->{'httpClient'}, $context);

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
			}elsif($reqParams->{'itemId'} =~ /.*\:playlist\:(.*)$/) {
				$item = getPlaylist($1);
			}elsif($reqParams->{'itemId'} =~ /.*\:folder\:(.*)$/) {
				$item = getFolder($1);
			}elsif($reqParams->{'itemId'} =~ /^.*\:category\:(.*)$/) {
				$item = getCategory($1);
			}
		}
	
		# the request was successful and is not async, send results back to caller!
		Plugins::IckStreamPlugin::JsonHandler::requestWrite($item, $context->{'httpClient'}, $context);
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
		} elsif(exists($reqParams->{'type'}) && $reqParams->{'type'} eq 'playlist') {
			$items = findPlaylists($reqParams,$offset,$count);
		} elsif(exists($reqParams->{'type'}) && $reqParams->{'type'} eq 'artist') {
			$items = findArtists($reqParams,$offset,$count);
		} elsif(exists($reqParams->{'type'}) && $reqParams->{'type'} eq 'track') {
			$items = findTracks($reqParams,$offset,$count);
		} elsif(exists($reqParams->{'type'}) && $reqParams->{'type'} eq 'category') {
			$items = findCategories($reqParams,$offset,$count);
		} elsif(exists($reqParams->{'contextId'}) && $reqParams->{'contextId'} eq 'myMusicFolder' && (!exists($reqParams->{'type'}) || $reqParams->{'type'} eq 'menu')) {
			$items = findFolders($reqParams,$offset,$count);
		}
		
		my $result;
		if(defined($items)) {	
			$result = {
				'offset' => $offset,
				'count' => scalar(@$items),
				'expirationTimestamp' => time()+24*3600,
				'items' => $items
			};
		}else {
			my @empty = ();
			$result = {
				'offset' => $offset,
				'count' => 0,
				'expirationTimestamp' => time(),
				'items' => \@empty
			};
		}
	
		# the request was successful and is not async, send results back to caller!
		Plugins::IckStreamPlugin::JsonHandler::requestWrite($result, $context->{'httpClient'}, $context);
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
	
	if ($serverPrefs->get('authorize')) {
		my $password = Crypt::Tea::decrypt($prefs->get('password'),$KEY);
		$serverAddress = $serverPrefs->get('username').":".$password."@".$serverAddress;
	}

	$serverAddress .= ":" . $serverPrefs->get('httpport');

	my $result = {
		'id' => getServiceId(),
		'name' => $serverName,
		'type' => 'content',
		'serviceUrl' => 'http://'.$serverAddress
	};
	# the request was successful and is not async, send results back to caller!
Plugins::IckStreamPlugin::JsonHandler::requestWrite($result, $context->{'httpClient'}, $context);
}

sub getProtocolVersions {
	my $context = shift;
	if ( $log->is_debug ) {
	        $log->debug( "getProtocolVersions()" );
	}
	my $result = {
		'minVersion' => '1.0',
		'maxVersion' => '1.0'
	};
	# the request was successful and is not async, send results back to caller!
	Plugins::IckStreamPlugin::JsonHandler::requestWrite($result, $context->{'httpClient'}, $context);
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
	Plugins::IckStreamPlugin::JsonHandler::requestWrite($result, $context->{'httpClient'}, $context);
}

sub getCategory {
	my $genreId = shift;

	my $sql = 'SELECT genres.id,genres.name,genres.namesort FROM genres ';
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	my $order_by = "genres.namesort $collate";

	my @whereDirectives = ();
	my @whereDirectiveValues = ();

	push @whereDirectives,'genres.name=?';
	push @whereDirectiveValues,$genreId;
	
	if(scalar(@whereDirectives)>0) {
		$sql .= 'WHERE ';
		my $whereDirective;
		if(scalar(@whereDirectives)>0) {
			$whereDirective = join(' AND ', @whereDirectives);
		}
		$sql .= $whereDirective . ' ';
	}
	$sql .= "GROUP BY genres.id ORDER BY $order_by";
	$sql .= " LIMIT 0, 1";

	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$log->debug("Using values: ".join(',',@whereDirectiveValues));
	$sth->execute(@whereDirectiveValues);

	my $items = processCategoryResult($sth,$order_by);
	my $item = pop @$items;
	return $item;
}

sub findCategories {
	my $reqParams = shift;
	my $offset = shift;
	my $count = shift;
	
	my @items = ();
	
	my @whereDirectives = ();
	my @whereDirectiveValues = ();
	my @whereSearchDirectives = ();
	my @whereSearchDirectiveValues = ();
	my $sql = 'SELECT genres.id,genres.name,genres.namesort FROM genres ';
	my $order_by = undef;
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	$order_by = "genres.namesort $collate";

	$sql .= "GROUP BY genres.id ORDER BY $order_by";
	if(defined($count)) {
		$sql .= " LIMIT $offset, $count";
	}
	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$log->debug("Executing $sql");
	$log->debug("Using values: ".join(',',@whereDirectiveValues));
	$sth->execute(@whereDirectiveValues);

	return processCategoryResult($sth,$order_by);
}

sub processCategoryResult {
	my $sth = shift;
	my $order_by = shift;
		
	my $serverPrefix = getServerId();
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();

	my @items = ();
	
	my $genreId;
	my $genreName;
	my $genreSortName;
	
	$sth->bind_col(1,\$genreId);
	$sth->bind_col(2,\$genreName);
	$sth->bind_col(3,\$genreSortName);
	
	while ($sth->fetch) {
		utf8::decode($genreName);
		utf8::decode($genreSortName);
		
		my $item = {
			'id' => "$serverPrefix:category:$genreName",
			'text' => $genreName,
			'sortText' => $genreSortName,
			'type' => "category",
			'itemAttributes' => {
				'id' => "$serverPrefix:category:$genreName",
				'categoryType' => 'genre',
				'name' => $genreName
			}
		};
		
		$item->{'sortText'} = $genreSortName;
		
		push @items,$item;
	}
	$sth->finish();
	return \@items;		
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
		
		$sql .= ' AND contributor_album.role IN (?, ?, ?';
		push @whereDirectiveValues, Slim::Schema::Contributor->typeToRole('ARTIST');
		push @whereDirectiveValues, Slim::Schema::Contributor->typeToRole('TRACKARTIST');
		push @whereDirectiveValues, Slim::Schema::Contributor->typeToRole('ALBUMARTIST');
		foreach (Slim::Schema::Contributor->contributorRoles) {
			if ($serverPrefs->get(lc($_) . 'InArtists')) {
				$sql .= ', ?';
				push @whereDirectiveValues, Slim::Schema::Contributor->typeToRole($_);
			}
		}
		$sql .= ') ';

		push @whereDirectives, 'contributor_album.contributor=?';
		push @whereDirectiveValues, getInternalId($reqParams->{'artistId'});
		if($prefs->get('orderAlbumsForArtist') eq 'by_year_title') {
			$order_by = "albums.year desc, albums.titlesort $collate, albums.disc";
		}else {
			$order_by = "albums.titlesort $collate, albums.disc";
		}
	}else {
		$sql .= 'JOIN contributors on contributors.id = albums.contributor ';
		$order_by = "albums.titlesort $collate, albums.disc";
	}
	
	if(exists($reqParams->{'categoryId'})) {
		$sql .= 'JOIN tracks on tracks.album = albums.id ';
		$sql .= 'JOIN genre_track on genre_track.track = tracks.id ';
		$sql .= 'JOIN genres on genres.id = genre_track.genre ';

		push @whereDirectives, 'genres.name=? ';
		push @whereDirectiveValues, getInternalId($reqParams->{'categoryId'});
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
	$sth->finish();
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
	
	my $va_pref = $serverPrefs->get('variousArtistAutoIdentification');
	
	my @whereDirectives = ();
	my @whereDirectiveValues = ();
	my $sql = 'SELECT contributors.id,contributors.name,contributors.namesort FROM contributors JOIN contributor_album ON contributors.id=contributor_album.contributor ';
	if(!exists($reqParams->{'search'})) {
		$sql .= ' AND contributor_album.role IN (';
		my $roles = Slim::Schema->artistOnlyRoles || [];
		my $first = 1;
		foreach (@{$roles}) {
			if(!$first) {
				$sql .= ', ';
			}
			$sql .= '?';
			push @whereDirectiveValues, $_;
			$first = 0;
		}
		$sql .= ') ';
		
		if($va_pref) {
			$sql .= 'JOIN albums ON contributor_album.album = albums.id ';
			push @whereDirectives, '(albums.compilation IS NULL OR albums.compilation = 0)';
		}
	}

	if(exists($reqParams->{'categoryId'})) {
		$sql .= 'JOIN contributor_track on contributor_track.contributor=contributor_album.contributor ';
		$sql .= 'JOIN tracks on tracks.id = contributor_track.track ';
		$sql .= 'JOIN genre_track on genre_track.track = tracks.id ';
		$sql .= 'JOIN genres on genres.id = genre_track.genre ';

		push @whereDirectives, 'genres.name=? ';
		push @whereDirectiveValues, getInternalId($reqParams->{'categoryId'});
	}

	my $order_by = undef;
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	$order_by = "contributors.namesort $collate";

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
	$sth->finish();
	return \@items;		
}

sub findPlaylists {
	my $reqParams = shift;
	my $offset = shift;
	my $count = shift;
	
	my $serverPrefix = getServerId();

	my @items = ();
	
	my $sql = 'SELECT tracks.urlmd5,tracks.title,tracks.titlesort FROM tracks ';
	my $order_by = undef;
	my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
	$order_by = "tracks.titlesort $collate";

	my @whereDirectives = ('tracks.content_type=?');
	my @whereDirectiveValues = ('ssp');
	my @whereSearchDirectives = ();
	my @whereSearchDirectiveValues = ();
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
	if(scalar(@whereDirectiveValues)>0) {
		$log->debug("Using values: ".join(',',@whereDirectiveValues));
		$sth->execute(@whereDirectiveValues);
	}else {
		$sth->execute();
	}
	return processPlaylistResult($sth);	
}

sub processPlaylistResult {
	my $sth = shift;
	
	my $serverPrefix = getServerId();

	my @items = ();
	
	my $playlistId;
	my $playlistName;
	my $playlistSortName;
	
	$sth->bind_col(1,\$playlistId);
	$sth->bind_col(2,\$playlistName);
	$sth->bind_col(3,\$playlistSortName);
	
	while ($sth->fetch) {
		utf8::decode($playlistName);
		utf8::decode($playlistSortName);
		
		my $item = {
			'id' => "$serverPrefix:playlist:$playlistId",
			'text' => $playlistName,
			'sortText' => $playlistSortName,
			'type' => "playlist",
			'itemAttributes' => {
				'id' => "$serverPrefix:playlist:$playlistId",
				'name' => $playlistName
			}
		};
		
		push @items,$item;
	}
	$sth->finish();
	return \@items;		
}

sub getTrack {
	my $trackId = shift;
	
	my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album LEFT JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id ';
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

sub getPlaylist {
	my $trackId = shift;
	
	my $sql = 'SELECT tracks.urlmd5,tracks.title,tracks.titlesort FROM tracks ';
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

	my $items = processPlaylistResult($sth,undef);
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
	my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album LEFT JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id ';
	my $order_by = "tracks.disc,tracks.tracknum,tracks.titlesort";
	if(exists($reqParams->{'playlistId'})) {
		my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
		$sql .= 'JOIN playlist_track ON playlist_track.track = tracks.url ';
		$sql .= 'JOIN tracks AS playlists ON playlists.id = playlist_track.playlist ';
		push @whereDirectives, 'playlists.urlmd5=?';
		push @whereDirectiveValues, getInternalId($reqParams->{'playlistId'});
		$order_by = "playlist_track.position";
	}
	if(exists($reqParams->{'artistId'})) {
		my $collate = Slim::Utils::OSDetect->getOS()->sqlHelperClass()->collate();
		$sql .= 'JOIN contributor_track ON contributor_track.track = tracks.id ';
		push @whereDirectives, 'contributor_track.contributor=?';
		push @whereDirectiveValues, getInternalId($reqParams->{'artistId'});
	}
	if(exists($reqParams->{'categoryId'})) {
		$sql .= 'JOIN genre_track on genre_track.track = tracks.id ';
		$sql .= 'JOIN genres on genres.id = genre_track.genre ';

		push @whereDirectives, 'genres.name=? ';
		push @whereDirectiveValues, getInternalId($reqParams->{'categoryId'});
	}
	if(exists($reqParams->{'albumId'})) {
		push @whereDirectives, 'tracks.album=?';
		push @whereDirectiveValues, getInternalId($reqParams->{'albumId'});
	}elsif(!exists($reqParams->{'playlistId'})) {
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
	my $contributorIds;
	my $contributorNames;
	
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
	$sth->bind_col(17,\$albumYear);
	$sth->bind_col(18,\$contributorIds);
	$sth->bind_col(19,\$contributorNames);

	my $serverAddress = Slim::Utils::Network::serverAddr();
	($serverAddress) = split /:/, $serverAddress;
	
	$serverAddress .= ":" . $serverPrefs->get('httpport');
	
	while ($sth->fetch) {
		utf8::decode($trackSortTitle);
		utf8::decode($trackTitle);
		utf8::decode($albumTitle);
		utf8::decode($contributorNames);
			
		my $sortText = (defined($trackDisc)?($trackDisc<10?"0".$trackDisc."-":$trackDisc."-"):"").(defined($trackNumber)?($trackNumber<10?"0".$trackNumber:$trackNumber):"");
		my $displayText = (defined($trackDisc)?$trackDisc."-":"").(defined($trackNumber)?$trackNumber:"").". ".$trackTitle;
		if(!$requestedAlbumId) {
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
		if(defined($contributorIds)) {
			my @contributorIdsArray = split('\|',$contributorIds);
			my @contributorNamesArray = split('\|',$contributorNames);
			my @contributors = ();
			while(scalar(@contributorIdsArray)>0) {
				my $id = shift @contributorIdsArray;
				my $name = shift @contributorNamesArray;
				push @contributors,{
					'id' => "$serverPrefix:artist:$id",
					'name' => $name
				};
			}
			@contributors = sort {
				$a->{'name'} cmp $b->{'name'}
			} @contributors;
			$item->{'itemAttributes'}->{'mainArtists'} = \@contributors;
		}
		push @items,$item;
	}
	$sth->finish();
	return \@items;		
}

sub findFolders {
	my $reqParams = shift;
	my $offset = shift;
	my $count = shift;
	
	my @items = ();
	if(!defined($count)) {
		$count = 200;
	}
	
	my $dbh = Slim::Schema->dbh;
	
	my $folderId = undef;
	if(exists($reqParams->{'menuId'})) {
		my $internalId = getInternalId($reqParams->{'menuId'});
		my $sql = "SELECT id from tracks where urlmd5=?";
		my $sth = $dbh->prepare_cached($sql);
		$sth->execute(($internalId));
		$sth->bind_col(1,\$folderId);
		if ($sth->fetch) {
		}else {
			$sth->finish();
			return \@items;
		}
		$sth->finish();
	}

	my $request = undef;
	if(defined($folderId)) {
		$request = Slim::Control::Request->new(undef, ["musicfolder",$offset,$count,"folder_id:".$folderId]);
	}else {
		$request = Slim::Control::Request->new(undef, ["musicfolder",$offset,$count]);
	}
	
	$request->execute();
	if($request->isStatusError()) {
		return \@items;
	}
	my $foundItems = $request->getResult("folder_loop");
	foreach my $it (@$foundItems) {
		if($it->{'type'} eq 'track') {
			my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album LEFT JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id WHERE tracks.id=? GROUP BY tracks.id';
			
			my $sth = $dbh->prepare_cached($sql);
			$sth->execute(($it->{'id'}));
		
			my $trackItems = processTrackResult($sth,undef);
			my $track = pop @$trackItems;
			if(defined($track)) {
				push @items,$track;
			}
		}elsif($it->{'type'} eq 'folder') {
			my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.title,tracks.titlesort FROM tracks WHERE id=?';
			
			my $sth = $dbh->prepare_cached($sql);
			$sth->execute(($it->{'id'}));

			my $folderItems = processFolderResult($sth,undef);
			my $folder = pop @$folderItems;
			if(defined($folder)) {
				push @items,$folder;
			}
		}
	}
	return \@items;
}

sub processFolderResult {
	my $sth = shift;
	my $requestedAlbumId = shift;
	
	my $serverPrefix = getServerId();
	my @items = ();

	my $trackId;
	my $trackUrl;
	my $trackMd5Url;
	my $trackTitle;
	my $trackSortTitle;
	
	$sth->bind_col(1,\$trackId);
	$sth->bind_col(2,\$trackUrl);
	$sth->bind_col(3,\$trackMd5Url);
	$sth->bind_col(4,\$trackTitle);
	$sth->bind_col(5,\$trackSortTitle);

	my $serverAddress = Slim::Utils::Network::serverAddr();
	($serverAddress) = split /:/, $serverAddress;
	
	$serverAddress .= ":" . $serverPrefs->get('httpport');
	
	while ($sth->fetch) {
		utf8::decode($trackSortTitle);
		utf8::decode($trackTitle);
			
		my $sortText = $trackSortTitle;
		my $displayText = $trackTitle;

		my $item = {
			'id' => "$serverPrefix:folder:$trackMd5Url",
			'text' => $trackTitle,
			'sortText' => $trackSortTitle,
			'type' => "menu",
			'itemAttributes' => {
				'id' => "$serverPrefix:folder:$trackMd5Url",
				'name' => $trackTitle
			}
		};
		
		push @items,$item;
	}
	$sth->finish();
	return \@items;		
}

sub getNextDynamicPlaylistTracks {
	my $context = shift;

	eval {
	    # get the JSON-RPC params
	    my $reqParams = $context->{'procedure'}->{'params'};
	
		if ( $log->is_debug ) {
		        $log->debug( "getNextDynamicPlaylistTracks(" . Data::Dump::dump($reqParams) . ")" );
		}
	
		my $count = $reqParams->{'count'} if exists($reqParams->{'count'});
		if(!defined($count)) {
			$count = 10;
		}
		
		my $selectionParameters = $reqParams->{'selectionParameters'} if exists($reqParams->{'selectionParameters'});
		if(!defined($selectionParameters)) {
			Plugins::IckStreamPlugin::JsonHandler::requestWrite(undef,$context->{'httpClient'}, $context, {
				'code' => -32602,
				'message' => 'Missing parameter: selectionParameters'
			});
			return;
		}
		if(!defined($selectionParameters->{'type'})) {
			Plugins::IckStreamPlugin::JsonHandler::requestWrite(undef,$context->{'httpClient'}, $context, {
				'code' => -32602,
				'message' => 'Missing parameter: selectionParameters.type'
			});
			return;
		}
		my $type = $selectionParameters->{'type'};
		
		my $items = undef;
		
		if($type eq 'RANDOM_ALL') {
			$items = queryNextDynamicPlaylistTracks($count);
		}elsif($type eq 'RANDOM_MY_LIBRARY') {
			$items = queryNextDynamicPlaylistTracks($count);
		}elsif($type eq 'RANDOM_MY_PLAYLISTS') {
			$items = queryNextDynamicPlaylistTracksFromMyPlaylists($count);
		}elsif($type eq 'RANDOM_FOR_ARTIST') {
			if(!defined($selectionParameters->{'data'})) {
				Plugins::IckStreamPlugin::JsonHandler::requestWrite(undef,$context->{'httpClient'}, $context, {
					'code' => -32602,
					'message' => 'Missing parameter: selectionParameters.data'
				});
			}
			if(!defined($selectionParameters->{'data'}->{'artist'}) && !defined($selectionParameters->{'data'}->{'artistId'})) {
				Plugins::IckStreamPlugin::JsonHandler::requestWrite(undef,$context->{'httpClient'}, $context, {
					'code' => -32602,
					'message' => 'Missing parameter: selectionParameters.data.playlist or selectionParameters.data.playlistId'
				});
			}
			$items = queryNextDynamicPlaylistTracksFromArtist($count,$selectionParameters->{'data'});
		}elsif($type eq 'RANDOM_FOR_PLAYLIST') {
			if(!defined($selectionParameters->{'data'})) {
				Plugins::IckStreamPlugin::JsonHandler::requestWrite(undef,$context->{'httpClient'}, $context, {
					'code' => -32602,
					'message' => 'Missing parameter: selectionParameters.data'
				});
			}
			if(!defined($selectionParameters->{'data'}->{'playlist'}) && !defined($selectionParameters->{'data'}->{'playlistId'})) {
				Plugins::IckStreamPlugin::JsonHandler::requestWrite(undef,$context->{'httpClient'}, $context, {
					'code' => -32602,
					'message' => 'Missing parameter: selectionParameters.data.playlist or selectionParameters.data.playlistId'
				});
			}
			$items = queryNextDynamicPlaylistTracksFromPlaylist($count, $selectionParameters->{'data'});
		}elsif($type eq 'RANDOM_FOR_CATEGORY') {
			if(!defined($selectionParameters->{'data'})) {
				Plugins::IckStreamPlugin::JsonHandler::requestWrite(undef,$context->{'httpClient'}, $context, {
					'code' => -32602,
					'message' => 'Missing parameter: selectionParameters.data'
				});
			}
			if(!defined($selectionParameters->{'data'}->{'category'}) && !defined($selectionParameters->{'data'}->{'categoryId'})) {
				Plugins::IckStreamPlugin::JsonHandler::requestWrite(undef,$context->{'httpClient'}, $context, {
					'code' => -32602,
					'message' => 'Missing parameter: selectionParameters.data.category or selectionParameters.data.categoryId'
				});
			}
			$items = queryNextDynamicPlaylistTracksFromCategory($count, $selectionParameters->{'data'});
		}
			
		my $result;
		if(defined($items)) {	
			$result = {
				'expirationTimestamp' => time(),
				'items' => $items
			};
		}else {
			my @empty = ();
			$result = {
				'expirationTimestamp' => time(),
				'items' => \@empty
			};
		}
	
		# the request was successful and is not async, send results back to caller!
		Plugins::IckStreamPlugin::JsonHandler::requestWrite($result, $context->{'httpClient'}, $context);
	};
    if ($@) {
		$log->error("An error occurred $@");
    }
}

sub queryNextDynamicPlaylistTracks {
	my $count = shift;
	
	my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album LEFT JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id GROUP BY tracks.id ORDER BY random() LIMIT 0,'.$count;

	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$sth->execute();

	my $items = processTrackResult($sth,undef);
	return $items;
}

sub queryNextDynamicPlaylistTracksFromMyPlaylists {
	my $count = shift;
	
	my $sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album JOIN playlist_track on playlist_track.track=tracks.url LEFT JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id GROUP BY tracks.id ORDER BY random() LIMIT 0,'.$count;

	my $dbh = Slim::Schema->dbh;
	my $sth = $dbh->prepare_cached($sql);
	$sth->execute();

	my $items = processTrackResult($sth,undef);
	return $items;
}

sub queryNextDynamicPlaylistTracksFromArtist {
	my $count = shift;
	my $parameters = shift;
	
	
	my $sql;
	my $sth = undef;
	if($parameters->{'artistId'} && getInternalId($parameters->{'artistId'})) {
		my $artistId = getInternalId($parameters->{'artistId'});
		$sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id WHERE ct.contributor=? GROUP BY tracks.id ORDER BY random() LIMIT 0,'.$count;

		my $dbh = Slim::Schema->dbh;
		$sth = $dbh->prepare_cached($sql);
		$sth->execute(($artistId));
	}elsif($parameters->{'artist'}) {
		my $artistName = $parameters->{'artist'};
		
		$sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id WHERE contributors.name=? GROUP BY tracks.id ORDER BY random() LIMIT 0,'.$count;
		my $dbh = Slim::Schema->dbh;
		$sth = $dbh->prepare_cached($sql);
		$sth->execute(($artistName));
	}

	if(defined($sth)) {
		my $items = processTrackResult($sth,undef);
		return $items;
	}else {
		return undef;
	}
}

sub queryNextDynamicPlaylistTracksFromPlaylist {
	my $count = shift;
	my $parameters = shift;
	
	
	my $sql;
	my $sth = undef;
	if($parameters->{'playlistId'} && getInternalId($parameters->{'playlistId'})) {
		my $artistId = getInternalId($parameters->{'playlistId'});
		$sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album JOIN playlist_track as pt on pt.track=tracks.url JOIN tracks as playlists on playlists.id=pt.playlist LEFT JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id WHERE playlists.urlmd5=? GROUP BY tracks.id ORDER BY random() LIMIT 0,'.$count;

		my $dbh = Slim::Schema->dbh;
		$sth = $dbh->prepare_cached($sql);
		$sth->execute(($artistId));
	}elsif($parameters->{'playlist'}) {
		my $playlistName = $parameters->{'playlist'};
		
		$sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album JOIN playlist_track as pt on pt.track=tracks.url JOIN tracks as playlists on playlists.id=pt.playlist LEFT JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id WHERE playlists.title=? GROUP BY tracks.id ORDER BY random() LIMIT 0,'.$count;
		my $dbh = Slim::Schema->dbh;
		$sth = $dbh->prepare_cached($sql);
		$sth->execute(($playlistName));
	}

	if(defined($sth)) {
		my $items = processTrackResult($sth,undef);
		return $items;
	}else {
		return undef;
	}
}

sub queryNextDynamicPlaylistTracksFromCategory {
	my $count = shift;
	my $parameters = shift;
	
	
	my $sql;
	my $sth = undef;
	my $categoryId = undef;
	if($parameters->{'categoryId'} && getInternalId($parameters->{'categoryId'})) {
		$categoryId = getInternalId($parameters->{'categoryId'});
	}elsif($parameters->{'category'}) {
		$categoryId = $parameters->{'category'};
	}
	if(defined($categoryId)) {
		$sql = 'SELECT tracks.id,tracks.url,tracks.urlmd5,tracks.samplerate,tracks.samplesize,tracks.channels,tracks.tracknum, tracks.title,tracks.titlesort,tracks.coverid,tracks.year,tracks.disc,tracks.secs,tracks.content_type,albums.id,albums.title,albums.year,group_concat(contributors.id,"|"), group_concat(contributors.name,"|") FROM tracks JOIN albums on albums.id=tracks.album JOIN contributor_track as ct on ct.track=tracks.id and ct.role in (1,5) JOIN contributors on ct.contributor=contributors.id JOIN genre_track on genre_track.track=tracks.id JOIN genres on genres.id=genre_track.genre WHERE genres.name=? GROUP BY tracks.id ORDER BY random() LIMIT 0,'.$count;

		my $dbh = Slim::Schema->dbh;
		$sth = $dbh->prepare_cached($sql);
		$sth->execute(($categoryId));
	}

	if(defined($sth)) {
		my $items = processTrackResult($sth,undef);
		return $items;
	}else {
		return undef;
	}
}

sub getInternalId {
	my $globalId = shift;
	
	if($globalId =~ /^[^:]*:lms:[^:]*:(.*)$/) {
		return $1;
	}else {
		return undef;
	}
}

sub getServiceId {
	return uc($prefs->get('uuid'));
}

sub getServerId {
	return getServiceId().":lms";
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
			$sth->finish();
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
		$sth->finish();
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
				Plugins::IckStreamPlugin::JsonHandler::generateJSONResponse($context, undef, {
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
				Plugins::IckStreamPlugin::JsonHandler::generateJSONResponse($context, undef, {
					'code' => -32601,
					'message' => 'Method not found',
					'data' => $method
				});
				return;
        }

        # figure out the method wanted
        my $funcPtr = $methods{$method};
        
        if (!$funcPtr) {

				Plugins::IckStreamPlugin::JsonHandler::generateJSONResponse($context, undef, {
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
        Plugins::IckStreamPlugin::JsonHandler::setContext($httpClient, $context);

        # jump to the code handling desired method. It is responsible to send a suitable output
        eval { &{$funcPtr}($context); };

        if ($@) {
                my $funcName = Slim::Utils::PerlRunTime::realNameForCodeRef($funcPtr);
                $log->error("While trying to run function coderef [$funcName]: [$@]");
                main::DEBUGLOG && $log->error( "JSON parsed procedure: " . Data::Dump::dump($procedure) );

				Plugins::IckStreamPlugin::JsonHandler::generateJSONResponse($context, undef, {
					'code' => -32001,
					'message' => 'Error when executing $funcName',
					'data' => $@
				});
				return;
        }
}

1;