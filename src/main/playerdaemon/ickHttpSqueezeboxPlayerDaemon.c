#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <signal.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <pthread.h>
#include "ickP2p.h"

#define closesocket(s) close(s)
#define last_error() errno


char* networkAddress = NULL;
int daemonPort = 9001;
char* wrapperURL = NULL;
char wrapperIP[16];
int wrapperPort = 80;
char wrapperPath[1024];
char* wrapperDiscoveryPath = NULL;
char* wrapperAuthorization = NULL;
int bShutdown = 0;
ickP2pContext_t* g_context = NULL;

void messageCb(ickP2pContext_t *ictx, const char *szSourceDeviceId, ickP2pServicetype_t sourceService, ickP2pServicetype_t targetService, const char* message, size_t messageLength, ickP2pMessageFlag_t mFlags );
void discoveryCb(ickP2pContext_t *ictx, const char *szDeviceId, ickP2pDeviceState_t change, ickP2pServicetype_t type);

void set_nonblock(int s) {
	int flags = fcntl(s, F_GETFL,0);
	fcntl(s, F_SETFL, flags | O_NONBLOCK);
}

struct _ickP2pPlayerContext;
struct _ickP2pPlayerContext {
    ickP2pContext_t* context;
    char* deviceId;
    struct _ickP2pPlayerContext* next;
};

struct _ickP2pPlayerContext *contexts = NULL;
pthread_mutex_t contextMutex;

void addPlayerForContext(ickP2pContext_t* context, char* deviceId) {

    struct _ickP2pPlayerContext* entry = malloc(sizeof(struct _ickP2pPlayerContext) );
    entry->context = context;
    entry->deviceId = malloc(strlen(deviceId)+1);
    strcpy(entry->deviceId,deviceId);
    entry->next=NULL;

    pthread_mutex_lock( &contextMutex );

    if(contexts == NULL) {
        contexts = entry;
    }else {
        struct _ickP2pPlayerContext* next = contexts;
        while(next->next != NULL) {
            next = next->next;
        }
        next->next = entry;
    }

    pthread_mutex_unlock( &contextMutex );
}

ickP2pContext_t* getContextForPlayer(char* deviceId) {
    ickP2pContext_t* context = NULL;
    pthread_mutex_lock( &contextMutex );

    if(contexts != NULL) {
        struct _ickP2pPlayerContext* next = contexts;
        while(next != NULL) {
        	if(strcmp(deviceId,next->deviceId)==0) {
                context = next->context;
                break;
            }
            next = next->next;
        }
    }

    pthread_mutex_unlock( &contextMutex );
    return context;
}

void removePlayerForContext(ickP2pContext_t* context) {
    pthread_mutex_lock( &contextMutex );

    if(contexts != NULL) {
        if(contexts->context == context) {
           	free(contexts->deviceId);
			free(contexts);
			contexts = contexts->next;
        }else {
            struct _ickP2pPlayerContext* next = contexts;
            while(next->next != NULL) {
                if(next->next->context==context) {
                	struct _ickP2pPlayerContext* deleted = next->next;
	                next->next = next->next->next;
	                free(deleted->deviceId);
	                free(deleted);
                    break;
                }
                next = next->next;
            }
        }
    }

    pthread_mutex_unlock( &contextMutex );
}

void initPlayer(char* deviceId, char* deviceName) {
    printf("Initializing ickP2P for %s(%s) at %s...\n",deviceName,deviceId,networkAddress);
    printf("Wrapping URL: %s\n",wrapperURL);
    printf("- Using IP-address: %s\n",wrapperIP);
    printf("- Using port: %d\n",wrapperPort);
    printf("- Using path: /%s\n",wrapperPath);
    
	ickErrcode_t error;
    printf("create(\"%s\",\"%s\",NULL,0,0,%d,%p)\n",deviceName,deviceId,ICKP2P_SERVICE_PLAYER,&error);
	ickP2pContext_t* context = ickP2pCreate(deviceName,deviceId,NULL,0,0,ICKP2P_SERVICE_PLAYER,&error);
	if(error == ICKERR_SUCCESS) {
		printf("context = %p\n",context);
    	error = ickP2pRegisterMessageCallback(context, &messageCb);
    	if(error != ICKERR_SUCCESS) {
    		printf("ickP2pRegisterMessageCallback failed=%d\n",(int)error);
    	}
    	error = ickP2pRegisterDiscoveryCallback(context, &discoveryCb);
    	if(error != ICKERR_SUCCESS) {
    		printf("ickP2pRegisterDiscoveryCallback failed=%d\n",(int)error);
    	}
#ifdef ICK_DEBUG
	    ickP2pSetHttpDebugging(context,1);
#endif
		error = ickP2pAddInterface(context, networkAddress, NULL);
    	if(error != ICKERR_SUCCESS) {
    		printf("ickP2pAddInterface failed=%d\n",(int)error);
    	}
    	error = ickP2pResume(context);
    	if(error != ICKERR_SUCCESS) {
    		printf("ickP2pResume failed=%d\n",(int)error);
    	}
		addPlayerForContext(context,deviceId);
		sleep(1);
	}
	fflush (stdout);
}

void writeSuccessResponse(int fd) {
	char answer[] = "HTTP/1.1 200 OK\r\nServer: ickHttpSqueezeboxPlayerDaemon\r\nConnection: close\r\nContent-Type: application/json\r\n\r\n";
	int size = send(fd,answer,strlen(answer),0);
	if(size<strlen(answer)) {
		printf("Unable to write whole response: %s\n",answer);
	}
	closesocket(fd);
}

void writeErrorResponse(int fd, const char* error) {
	char template[] = "HTTP/1.1 %s\r\nServer: ickHttpSqueezeboxPlayerDaemon\r\nConnection: close\r\nContent-Type: application/json\r\n\r\n";
	char* answer = malloc(strlen(template)+100);
	sprintf(answer,template,error);
	int size = send(fd,answer,strlen(answer),0);
	if(size<strlen(answer)) {
		printf("Unable to write whole response: %s\n",answer);
	}
	free(answer);
	closesocket(fd);
}

void httpServer(int listenfd)
{
	while(!bShutdown) {
		int fd;
		
		printf("Waiting for new connection in accept\n");
		socklen_t addrlen;
		struct sockaddr_in address;
		addrlen = sizeof(struct sockaddr_in);
  		fd = accept(listenfd, (struct sockaddr *)&address, &addrlen);
		if(fd > 0) {

			char buffer[1024];
			char *method = NULL, *path = NULL, *prot = NULL, *res = NULL, *req = NULL, *par = NULL, *auth = NULL, *line = NULL;

			fd_set read_set;
			struct timeval tv;
		
			FD_ZERO(&read_set);
			FD_SET(fd, &read_set);
			tv.tv_sec = 2;
			tv.tv_usec = 0;

			printf("Waiting for select\n");
			// wait up to 2 secs for fd to be readable - sp can delay sending request
			if (select((int)fd + 1, &read_set, NULL, &read_set, &tv) > 0) {
			
				int flags = fcntl(fd, F_GETFL,0);
				fcntl(fd, F_SETFL, flags | O_NONBLOCK);
				
				char* completeBuffer = NULL;
				int completeBufferSize = 0;
				printf("Recv from socket\n");
				int n=0;
				do {
					n = recv(fd, buffer, 1023, 0);
					if(n>0) {
						if(completeBuffer == NULL) {
							completeBuffer = malloc(n+1);
							memcpy(completeBuffer,buffer,n);
							completeBufferSize=n;
						}else {
							char* oldCompleteBuffer = completeBuffer;
							completeBuffer = malloc(completeBufferSize+n+1);
							memcpy(completeBuffer,oldCompleteBuffer,completeBufferSize);
							free(oldCompleteBuffer);
							memcpy(completeBuffer+completeBufferSize,buffer,n);
							completeBufferSize+=n;
						}
						*(completeBuffer+completeBufferSize) = '\0';
					}
				}while(n==1023);
				
				if(completeBuffer != NULL) {
					char *strtokContext = NULL;
					char* body = strstr(completeBuffer,"\r\n\r\n");
					if(body != NULL) {
						*body='\0';
						body+=4;
					}else {
						printf("No body available\n");
						printf("========\n");
						printf(completeBuffer);
						printf("========\n");
					}
					method = strtok_r(completeBuffer, " \n\r",&strtokContext);
					path   = strtok_r(NULL, " \n\r",&strtokContext);
					prot   = strtok_r(NULL, " \n\r",&strtokContext);
	
					// find additional headers
					while ((line = strtok_r(NULL, "\n\r",&strtokContext))) {
						if (!strncmp(line, "Authorization:", 14)) {
							auth = line + 14;
						}
					}
					if (auth) {
						char* fromDeviceId = strtok_r(auth, " \n\r",&strtokContext);
	
						// split path from param
						path = strtok_r(path, "?",&strtokContext);
		
						// split path: res = resource (null for search), req = request
						char* command = strtok_r(path, "/",&strtokContext);
						char* toDeviceId = strtok_r(NULL, "/",&strtokContext);
	
						printf("GOT: \nMETHOD: %s\nPATH: %s\nPROT: %s\nCommand: %s\nFrom: %s\nTo: %s\nData: %s\n",method,path,prot,command,fromDeviceId,toDeviceId,body);
						fflush (stdout);
						if(strcmp(command,"start")==0) {
							char* deviceName = strtok_r(body, "\n\r",&strtokContext);
							if(deviceName == NULL) {
								deviceName = fromDeviceId;
							}
							ickP2pContext_t* context = getContextForPlayer(fromDeviceId);
							if(context == NULL) {
								initPlayer(fromDeviceId,deviceName);
							}else {
								printf("Player already initialized\n");
							}
						    writeSuccessResponse(fd);
						}else if(strcmp(command,"sendMessage")==0) {
							char* toServiceString = strtok_r(NULL, "?",&strtokContext);
							int toService = ICKP2P_SERVICE_ANY;
							if(toServiceString != NULL) {
								toService = atoi(toServiceString);
							}
							ickP2pContext_t* context = getContextForPlayer(fromDeviceId);
							if(context != NULL) {
								ickErrcode_t error = ickP2pSendMsg(context,toDeviceId,toService,ICKP2P_SERVICE_PLAYER,body,strlen(body));
								if(error != ICKERR_SUCCESS) {
									printf("Error sending message to %s(%d): %d\n", toDeviceId,toService,error);
									writeErrorResponse(fd,"500 Internal Server Error");
								}else {
								    writeSuccessResponse(fd);
								}
							}else {
								writeErrorResponse(fd, "401 Unauthorized");
							}
						}else if(strcmp(command,"stop") == 0) {
							ickP2pContext_t* context = getContextForPlayer(fromDeviceId);
							if(context != NULL) {
							    printf("Shutting down ickP2P for %s\n",fromDeviceId);
								fflush (stdout);
							    ickP2pEnd(context,NULL);
							    printf("Removing context for %s\n",fromDeviceId);
								fflush (stdout);
							    removePlayerForContext(context);
							    printf("Shutdown ickP2P for %s\n",fromDeviceId);
								fflush (stdout);
							    writeSuccessResponse(fd);
							}else {
								writeErrorResponse(fd, "401 Unauthorized");
							}
						}else {
							writeErrorResponse(fd, "404 Not Found");
						}
							
					}else {
						writeErrorResponse(fd,"401 Unauthorized");
					}
					free(completeBuffer);
				}
			}
			
		}else {
			fprintf(stderr, "Fail to accept socket: %d\n",errno);
		}
	}
	closesocket(listenfd);
}

char* httpRequest(const char* ip, int port, const char* path, const char* authorization, const char* fromDeviceId, ickP2pServicetype_t fromService, const char* toDeviceId, const char* requestData)
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
	char FROM_DEVICE_ID[]="fromDeviceId=";
	char FROM_SERVICE[]="fromService=";
	char TO_DEVICE_ID[]="toDeviceId=";
	char *pathAndParameters = malloc(strlen(path)+1+strlen(FROM_DEVICE_ID)+strlen(fromDeviceId)+1+strlen(FROM_SERVICE)+2+1+strlen(TO_DEVICE_ID)+strlen(toDeviceId)+1);
	sprintf(pathAndParameters, "%s?%s%s&%s%d&%s%s",path,FROM_DEVICE_ID,fromDeviceId,FROM_SERVICE,fromService,TO_DEVICE_ID,toDeviceId);
	char *requestHeader;
	const int CONTENT_LENGTH_SPACE = 10; // just allocate enough
	if(authorization != NULL) {
		requestHeader = "POST /%s HTTP/1.0\r\nHost: %s\r\nAuthorization: Basic %s\r\nX-Scanner: 1\r\nUser-Agent: ickHttpSqueezeboxPlayerDaemon/1.0\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s";
		request = (char*)malloc(strlen(requestHeader)+strlen(authorization)+strlen(ip)+strlen(pathAndParameters)+CONTENT_LENGTH_SPACE+strlen(requestData)-8+1+23);
		sprintf(request,requestHeader,pathAndParameters,ip,authorization,strlen(requestData),requestData);
	}else {
		requestHeader = "POST /%s HTTP/1.0\r\nHost: %s\r\nUser-Agent: ickHttpSqueezeboxPlayerDaemon/1.0\r\nContent-Type: application/json\r\nContent-Length: %d\r\n\r\n%s";
		request = (char*)malloc(strlen(requestHeader)+strlen(ip)+strlen(pathAndParameters)+CONTENT_LENGTH_SPACE+strlen(requestData)-8+1);
		sprintf(request,requestHeader,pathAndParameters,ip,strlen(requestData),requestData);
	}
	int sent = 0;
	while(sent < strlen(request)) {
		//printf("Forwarding request: ===============\n%s\n==============\n",request);
		int bytes_sent = send(server_socket, request, strlen(request), 0);
		if(bytes_sent < 0) {
			fprintf(stderr, "Error when forwarding request data: %d\n",bytes_sent);
			goto httpRequest_end;
		}
		sent = sent + bytes_sent;
	}
	printf("Request successfully sent to perl module via HTTP\n");
	fflush (stdout);
	free(pathAndParameters);

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
			fprintf(stderr, "Error allocating memory for response via HTTP\n");
			goto httpRequest_end;
		}
	}
	if(bytes_received<0) {
			fprintf(stderr, "Error reading response via HTTP: %d\n",errno);
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

void discoveryCb(ickP2pContext_t *ictx, const char *szDeviceId, ickP2pDeviceState_t change, ickP2pServicetype_t service)
{
    printf("DISCOVERY %s type=%d services=%d\n",szDeviceId,(int)change,(int)service);
	fflush (stdout);
	const char* destinationDeviceId = ickP2pGetDeviceUuid(ictx);
	if(change == ICKP2P_CONNECTED) {
		httpRequest(wrapperIP, wrapperPort, wrapperDiscoveryPath,wrapperAuthorization, szDeviceId, service, destinationDeviceId, "{\"status\": \"CONNECTED\"}");
	}else if(change==ICKP2P_DISCONNECTED) {
		httpRequest(wrapperIP, wrapperPort, wrapperDiscoveryPath,wrapperAuthorization, szDeviceId, service, destinationDeviceId, "{\"status\": \"DISCONNECTED\"}");
	}
}

void messageCb(ickP2pContext_t *ictx, const char *szSourceDeviceId, ickP2pServicetype_t sourceService, ickP2pServicetype_t targetService, const char* message, size_t messageLength, ickP2pMessageFlag_t mFlags )
{
	char* terminatedMessage = NULL;
	if(messageLength>0) {
		terminatedMessage = malloc(messageLength+1);
		memcpy(terminatedMessage,message,messageLength);
		terminatedMessage[(int)messageLength]='\0';
		printf("%p: From %s: %s\n", ictx , szSourceDeviceId, terminatedMessage);
	}else {
		printf("%p: From %s: %s\n", ictx , szSourceDeviceId, message);
	}
	fflush (stdout);
	const char* destinationDeviceId = ickP2pGetDeviceUuid(ictx);
	char* response = NULL;
	if(terminatedMessage != NULL) {
		response = httpRequest(wrapperIP, wrapperPort, wrapperPath,wrapperAuthorization, szSourceDeviceId, sourceService, destinationDeviceId, terminatedMessage);
	}else {
		response = httpRequest(wrapperIP, wrapperPort, wrapperPath,wrapperAuthorization, szSourceDeviceId, sourceService, destinationDeviceId, message);
	}
    if( response ) {
        printf("To %s: %s\n",szSourceDeviceId, response);
        fflush (stdout);
        ickErrcode_t error = ickP2pSendMsg(ictx,szSourceDeviceId, sourceService,ICKP2P_SERVICE_SERVER_GENERIC,response, strlen(response));
        if(error != ICKERR_SUCCESS) {
    		fprintf(stderr,"Failed to send response=%d\n",(int)error);
    	}
    }
	if(response != NULL) {
		free(response);
		response = NULL;
	}
	if(terminatedMessage != NULL) {
		free(terminatedMessage);
		terminatedMessage = NULL;
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
	if(argc != 6 && argc != 7) {
		printf("Usage: %s IP-address daemonPort wrapperURL logFile authorizationHeader\n",argv[0]);
		return 0;
	}
    networkAddress = argv[1];
    daemonPort = atoi(argv[2]);
	wrapperURL = argv[3];
	wrapperDiscoveryPath = argv[4];
	char* logFile = argv[5];
	if(argc == 7) {
		wrapperAuthorization = argv[6];
	}
	
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
		printf("Unable to parse path from URL\n");
		return 0;
	}

	
	int listenfd;
	listenfd = socket(AF_INET, SOCK_STREAM, 0);
	int on = 1;
	setsockopt(listenfd, SOL_SOCKET, SO_REUSEADDR, (const char *) &on, sizeof(on));

	struct sockaddr_in serv_addr;
	memset(&serv_addr, 0, sizeof(serv_addr));
	serv_addr.sin_family = AF_INET;
	serv_addr.sin_addr.s_addr = INADDR_ANY;
	serv_addr.sin_port = htons(daemonPort);

	printf("Binding socket %d to port: %d\n",listenfd,daemonPort);
	if (bind(listenfd, (struct sockaddr *) &serv_addr, sizeof(serv_addr)) < 0) {
		printf("Error on bind listenfd: %s", strerror(last_error()));
		return 0;
	}

	printf("Listening to socket\n");
	if(listen(listenfd, 20)!=0) {
		printf("Fail to listen to socket: %d\n",errno);
	}

    int fd1 = open( "/dev/null", O_RDWR, 0 );
    int fd2 = open( logFile, O_RDWR|O_CREAT|O_TRUNC, 0644 );
    if( fd1!=-1) {
      dup2(fd1, fileno(stdin));
    }
    if( fd2!=-1) {
      dup2(fd2, fileno(stdout));
      dup2(fd2, fileno(stderr));
    }

#ifdef DEBUG
    printf("ickP2pSetLogLevel(7)\n");
    ickP2pSetLogging(7,stderr,100);
#elif ICK_DEBUG
    ickP2pSetLogging(6,NULL,100);
#endif

    struct sigaction act;
    memset( &act, 0, sizeof(act) );
    act.sa_sigaction = &shutdownHandler;
    act.sa_flags     = SA_SIGINFO;
    sigaction( SIGINT, &act, NULL );
    sigaction( SIGTERM, &act, NULL );

	httpServer(listenfd);
	
	return 1;
}
