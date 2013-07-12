#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <errno.h>
#include "ickDiscovery.h"

char* wrapperURL = NULL;
char wrapperIP[16];
int wrapperPort = 80;
char wrapperPath[1024];
int bShutdown = 0;

char* httpRequest(const char* ip, int port, const char* path, const char* requestData)
{
	int SIZE = 1023;
	char buffer[SIZE+1];
	char *request = NULL;
    char *responseData = NULL;
	char* responseBody = NULL;
    struct sockaddr_in * server_addr = NULL;
	int server_socket = socket(AF_INET, SOCK_STREAM, 0);
	if(server_socket < 0) {
		fprintf(stderr, "Unable to open socket: %d\n",server_socket);
		goto httpRequest_end;
	}

	//printf("Getting address for %s and port %d\n",ip,port);
	server_addr = (struct sockaddr_in *) malloc(sizeof(struct sockaddr_in));
	server_addr->sin_family = AF_INET;
	server_addr->sin_port = htons(port);
	if(inet_pton(AF_INET,ip,(void *)(&(server_addr->sin_addr.s_addr))) <= 0) {
		fprintf(stderr,"Unable to convert string IP to byte IP using inet_pton\n");
		goto httpRequest_end;
	}
	bzero(&(server_addr->sin_zero), 8);
	
	struct timeval tv;
	tv.tv_sec = 30;  // 30 Secs Timeout
	tv.tv_usec = 0;  // Not init'ing this can cause strange errors
	setsockopt(server_socket,SOL_SOCKET,SO_RCVTIMEO,(char *)&tv,sizeof(struct timeval));

	int rc = connect(server_socket, 
		(struct sockaddr *) server_addr, 
		sizeof(struct sockaddr));
	if(rc < 0) {
		fprintf(stderr, "Fail to connect to socket: %d\n",errno);
		goto httpRequest_end;
	}
	char *requestHeader = "POST /%s HTTP/1.0\r\nHost: %s\r\nUser-Agent: ickHttpWrapperDaemon/1.0\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s";
	const int CONTENT_LENGTH_SPACE = 10; // just allocate enough
	request = (char*)malloc(strlen(requestHeader)+strlen(ip)+strlen(path)+CONTENT_LENGTH_SPACE+strlen(requestData)-8+1);
	sprintf(request,requestHeader,path,ip,strlen(requestData),requestData);
	int sent = 0;
	while(sent < strlen(request)) {
		//printf("Sending request: \n%s\n",request);
		int bytes_sent = send(server_socket, request, strlen(request), 0);
		if(bytes_sent < 0) {
			fprintf(stderr, "Error when sending request data: %d\n",bytes_sent);
			goto httpRequest_end;
		}
		sent = sent + bytes_sent;
	}

	//printf("Starting to read data\n");
	int bytes_received = 0;
	int total_bytes_received = 0;
	while((bytes_received = recv(server_socket, buffer, SIZE, 0)) > 0) {
		buffer[bytes_received] = '\0';
		responseData = realloc(responseData,total_bytes_received+bytes_received+1);
		if(responseData != NULL) {
			memcpy(responseData+total_bytes_received, buffer, bytes_received + 1);
			total_bytes_received += bytes_received;
		}else {
			fprintf(stderr, "Error when reading request data\n");
			goto httpRequest_end;
		}
	}

	//printf("Finished reading, total=%d, last=%d\n",total_bytes_received,bytes_received);
	if(responseData != NULL) {
		char *bodyOffset = strstr(responseData, "\r\n\r\n");
		if(bodyOffset != NULL) {
			int bodySize = total_bytes_received-(bodyOffset+4-responseData)+1;
			responseBody = malloc(bodySize);
			memcpy(responseBody, bodyOffset+4, bodySize);
			//printf("Got body:\n%s\n",responseBody);
		}
	}
httpRequest_end:
	if(request) {
		free(request);
	}
	if(server_socket>=0) {
		close(server_socket);
	}
	if(server_addr) {
		free(server_addr);
	}
	if(responseData != NULL) {
		free(responseData);
	}
	return responseBody;
}

void onMessage(const char * szSourceDeviceId, const char * message, size_t messageLength, enum ickMessage_communicationstate state, ickDeviceServicetype_t service_type, const char * szTargetDeviceId)
{
	printf("From %s: %s\n",szSourceDeviceId, message);
	char* response = httpRequest(wrapperIP, wrapperPort, wrapperPath,message);
    if( response ) {
        printf("To %s: %s\n",szSourceDeviceId, response);
    	if(ickDeviceSendMsg(szSourceDeviceId, response, strlen(response)) != ICKMESSAGE_SUCCESS) {
    		fprintf(stderr,"Failed to send response\n");
    	}
    }
	if(response != NULL) {
		free(response);
		response = NULL;
	}
}
	
static void shutdownHandler( int sig, siginfo_t *siginfo, void *context )
{
    switch( sig) {
        case SIGINT:
        case SIGTERM:
            bShutdown = sig;
            break;
        default:
            break;
	}
}

int main( int argc, char *argv[] )
{
	if(argc != 5) {
		printf("Usage: %s IP-address deviceId deviceName wrapperURL\n",argv[0]);
		return 0;
	}
    char* networkAddress = argv[1];
	char* deviceId = argv[2];
	char* deviceName = argv[3];
	wrapperURL = argv[4];
	
    char host[100];
	memset(wrapperPath, 0, 1024);
	memset(host, 0, 100);
	printf("Parsing url...%s\n",wrapperURL);
	sscanf(wrapperURL, "http://%99[^:]:%99d/%99[^\n]", host, &wrapperPort, wrapperPath);
	printf("Parsed...\n");
	if(strlen(host)==0) {
		printf("Unable to parse host from URL\n");
		return 0;
	}else {
		printf("Parsed url: %s, %d, %s\n",host,wrapperPort,wrapperPath);
		struct hostent *hent = NULL;
		memset(wrapperIP, 0, 16);
		if((hent = (struct hostent *)gethostbyname(host)) == NULL)
		{
			printf("Unable to get host information for hostname\n");
			return 0;
		}
		if(inet_ntop(AF_INET, (void *)hent->h_addr_list[0], wrapperIP, 15) == NULL)
		{
			printf("Can't resolve host to IP\n");
			return 0;
		}
	}
	if(strlen(wrapperPath)==0) {
		printf("Unable to parse path from URL");
		return 0;
	}
	
    printf("Initializing ickP2P for %s(%s) at %s...\n",deviceName,deviceId,networkAddress);
    printf("Wrapping URL: %s\n",wrapperURL);
    printf("- Using IP-address: %s\n",wrapperIP);
    printf("- Using port: %d\n",wrapperPort);
    printf("- Using path: /%s\n",wrapperPath);
    
    ickDeviceRegisterMessageCallback(&onMessage);
    ickDiscoveryResult_t result = ickInitDiscovery(deviceId, networkAddress,NULL);
    result = ickDiscoverySetupConfigurationData(deviceName, NULL);
    result = ickDiscoveryAddService(ICKDEVICE_SERVER_GENERIC);

    struct sigaction act;
    memset( &act, 0, sizeof(act) );
    act.sa_sigaction = &shutdownHandler;
    act.sa_flags     = SA_SIGINFO;
    sigaction( SIGINT, &act, NULL );
    sigaction( SIGTERM, &act, NULL );

    while (!bShutdown) {
    	sleep(1000);
    }
    printf("Shutting down ickP2P for %s\n",deviceName);
    ickEndDiscovery(1);
    printf("Shutdown ickP2P for %s\n",deviceName);
	return 1;
}
