#include "moonshine-c-api.h"
#include <stdio.h>
#include <stdlib.h>
int main(){for(int a=0;a<6;a++){if(a==3)continue;char value[8];sprintf(value,"%d",a);struct moonshine_option_t opt={"model_arch",value};char *json=NULL;int e=moonshine_get_stt_dependencies("en",&opt,1,&json);if(e)return e;printf("%d\t%s\n",a,json);free(json);}return 0;}
