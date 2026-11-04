#pragma once
#include <stdint.h>
#include <stddef.h>
static inline uint16_t vectorU16(const uint8_t *p){return p[0]|((uint16_t)p[1]<<8);}
static inline bool vectorPacketValid(const uint8_t *p,size_t len) {
  if(!p || len<19 || len>200*1024)return false;
  unsigned n=vectorU16(p+10);if(!n || n>7000)return false;
  size_t at=12;
  for(unsigned i=0;i<n;i++) {
    if(at+3>len)return false;
    unsigned cls=p[at],np=vectorU16(p+at+1);at+=3;
    if(!((cls>=1 && cls<=6)||(cls>=20 && cls<=26)||cls==138||cls==139))return false;
    unsigned minimum=cls>=128 ? 3 : cls>=20 ? 1 : 2;
    if(np<minimum || np>4096 || (size_t)np*4>len-at)return false;
    at+=np*4;
  }
  return at==len;
}
