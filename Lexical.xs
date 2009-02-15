#include "EXTERN.h"
#include "perl.h"

/*
 * chocolateboy 2009-02-08
 *
 * for binary compatibility (see perlapi.h), XS modules perform a function call to
 * access each and every interpreter variable. So, for instance, an innocuous-looking
 * reference to PL_op becomes:
 *
 *     (*Perl_Iop_ptr(my_perl))
 *
 * This (obviously) impacts performance. Internally, PL_op is accessed as:
 *
 *     my_perl->Iop
 *
 * (in threaded/multiplicity builds (see intrpvar.h)), which is significantly faster.
 *
 * defining PERL_CORE gets us the fast version, at the expense of a future maintenance release
 * possibly breaking things: http://www.xray.mpe.mpg.de/mailing-lists/perl5-porters/2008-04/msg00171.html
 *
 * Rather than globally defining PERL_CORE, which pokes its fingers into various headers, exposing
 * internals we'd rather not see, just define it for XSUB.h, which includes
 * perlapi.h, which imposes the speed limit.
 */

#define PERL_CORE
#include "XSUB.h"
#undef PERL_CORE

#define NEED_sv_2pv_flags
#include "ppport.h"

#include "hook_op_check.h"
#include "hook_op_annotation.h"
#include "mro.h"

#include <string.h> /* for strchr */
#define NDEBUG
#include <assert.h>

#define METHOD_LEXICAL_INSTALLED "Method::Lexical"

#define METHOD_LEXICAL_ENABLED(table, svp)                                                        \
    ((PL_hints & 0x20000) &&                                                                      \
    (table = GvHV(PL_hintgv)) &&                                                                  \
    (svp = hv_fetch(table, METHOD_LEXICAL_INSTALLED, strlen(METHOD_LEXICAL_INSTALLED), FALSE)) && \
    *svp &&                                                                                       \
    SvOK(*svp) &&                                                                                 \
    SvROK(*svp) &&                                                                                \
    SvRV(*svp) &&                                                                                 \
    SvTYPE(SvRV(*svp)) == SVt_PVHV)

typedef struct MethodLexicalDataList {
    const HV *stash;
    U32 generation;
    const CV *cv;
    const SV * method;
    struct MethodLexicalDataList *next;
} MethodLexicalDataList;

typedef struct MethodLexicalData {
    HV *hv;
    MethodLexicalDataList *list;
    U32 dynamic;
} MethodLexicalData;

STATIC CV *method_lexical_hash_get(pTHX_ HV * const hv, SV * const key);
STATIC HV *method_lexical_get_stash(pTHX_ SV * const invocant, char **packname_ptr);
STATIC MethodLexicalData * method_lexical_data_new(pTHX_ HV * const hv, const U32 dynamic);
STATIC OP *method_lexical_check_method_dynamic(pTHX_ OP * o);
STATIC OP *method_lexical_check_method(pTHX_ OP * o, void *user_data);
STATIC OP *method_lexical_check_method_static(pTHX_ OP * o);
STATIC OP *method_lexical_method_dynamic(pTHX);
STATIC OP *method_lexical_method_static(pTHX);
STATIC void method_lexical_data_free(pTHX_ void *data);
STATIC void method_lexical_data_list_free(pTHX_ void *vp);
STATIC void method_lexical_enter();
STATIC void method_lexical_leave();

STATIC MethodLexicalDataList * method_lexical_data_list_new(
    pTHX_
    const HV * const stash,
    const U32 generation,
    const SV * const method,
    const CV * const cv
);

STATIC SV *method_lexical_cache_get(
    pTHX_
    MethodLexicalData *data,
    const HV * const stash,
    const SV * const method,
    U32 * const retval
);

STATIC void method_lexical_cache_set(
    pTHX_
    MethodLexicalData * const data,
    const HV * const stash,
    const U32 generation,
    const SV * const method,
    const CV * const cv
);

STATIC SV * method_lexical_method_common(
    pTHX_
    MethodLexicalData * const data,
    const HV * const stash,
    const char * const class_name,
    const SV * const method
);

STATIC void method_lexical_cache_remove(
    pTHX_
    MethodLexicalData * const data,
    MethodLexicalDataList *prev,
    MethodLexicalDataList *head
);

STATIC hook_op_check_id method_lexical_check_method_id = 0;
STATIC OPAnnotationGroup METHOD_LEXICAL_ANNOTATIONS;
STATIC U32 METHOD_LEXICAL_COMPILING = 0;
STATIC U32 METHOD_LEXICAL_DEBUG = 0;

STATIC MethodLexicalData * method_lexical_data_new(pTHX_ HV * const hv, const U32 dynamic) {
    MethodLexicalData *data;

    Newx(data, 1, MethodLexicalData);

    if (!data) {
        croak("couldn't allocate annotation data");
    }

    data->hv = (HV * const)SvREFCNT_inc(hv); /* this is needed to prevent the hash being garbage-collected */
    data->dynamic = dynamic;
    data->list = NULL;

    return data;
}

STATIC void method_lexical_data_free(pTHX_ void *vp) {
    MethodLexicalData *data = (MethodLexicalData *)vp;

    if (data->list) {
        method_lexical_data_list_free(aTHX_ data->list);
    }

    SvREFCNT_dec(data->hv);
    Safefree(data);
}

STATIC MethodLexicalDataList * method_lexical_data_list_new(
    pTHX_
    const HV * const stash,
    const U32 generation,
    const SV * const method,
    const CV * const cv
) {
    MethodLexicalDataList *list;
    Newx(list, 1, MethodLexicalDataList);

    if (!list) {
        croak("couldn't allocate annotation data list");
    }

    /* the refcount increments are needed to prevent the values being garbage-collected */
    list->stash = (HV *const)SvREFCNT_inc(stash);
    list->method = method ? (SV * const)SvREFCNT_inc(method) : method;
    list->generation = generation;
    list->cv = (CV * const)SvREFCNT_inc(cv);
    list->next = NULL;

    return list;
}

STATIC void method_lexical_data_list_free(pTHX_ void *vp) {
    MethodLexicalDataList *list = (MethodLexicalDataList *)vp;
    MethodLexicalDataList *temp;

    while (list) {
        temp = list->next;
        SvREFCNT_dec(list->stash);
        SvREFCNT_dec(list->method);
        SvREFCNT_dec(list->cv);
        Safefree(list);
        list = temp;
    }
}

/*
 * the method name may be qualified e.g. 
 *
 *     $self->Foo::Bar::Baz($quux);
 *
 * in this case, we can turn it into a subroutine call:
 *
 *     Foo::Bar::Baz($self, $quux)
 *
 * XXX: Perl_ck_method does not turn fully-qualified names into OP_METHOD_NAMED
 * XXX: Perl_ck_method does not normalize fully-qualified names i.e. need to s/'/::/g
 */

STATIC OP * method_lexical_check_method(pTHX_ OP * o, void * user_data) {
     PERL_UNUSED_VAR(user_data);

    /*
     * Perl_ck_method can upgrade an OP_METHOD to an OP_METHOD_NAMED (perly.y
     * channels all method calls through newUNOP(OP_METHOD)),
     * so we need to assign the right method ppaddr, or bail if the OP's no
     * longer a method (i.e. another module has changed it)
     */

    if (o->op_type == OP_METHOD_NAMED) {
        return method_lexical_check_method_static(aTHX_ o);
    } else if (o->op_type == OP_METHOD) {
        return method_lexical_check_method_dynamic(aTHX_ o);
    }

    return o;
}

STATIC OP * method_lexical_check_method_dynamic(pTHX_ OP * o) {
    HV * table;
    SV ** svp;

    /* if there are bindings for the currently-compiling scope in $^H{METHOD_LEXICAL_INSTALLED} */
    if (METHOD_LEXICAL_ENABLED(table, svp)) {
        MethodLexicalData *data;
        HV *installed = (HV *)SvRV(*svp);

        data = method_lexical_data_new(aTHX_ installed, TRUE);
        (void)op_annotation_new(METHOD_LEXICAL_ANNOTATIONS, o, (void *)data, method_lexical_data_free);

        o->op_ppaddr = method_lexical_method_dynamic;
    }

    return o;
}

STATIC OP * method_lexical_check_method_static(pTHX_ OP * o) {
    HV * table;
    SV ** svp;

    /* if there are bindings for the currently-compiling scope in $^H{METHOD_LEXICAL_INSTALLED} */
    if (METHOD_LEXICAL_ENABLED(table, svp)) {
        STRLEN fqnamelen, namelen;
        HE *entry;
        HV *installed = (HV *)SvRV(*svp);
        UV count = 0;
        SV *method = cSVOPo->op_sv;
        const char *fqname, *name = SvPV_const(method, namelen);

        if (strchr(name, ':') || strchr(name, '\'')) {
            goto done;
        }

        hv_iterinit(installed);

        while ((entry = hv_iternext(installed))) {
            const char *rcolon;

            fqname = HePV(entry, fqnamelen);

            /*
             * There are 2 options:
             *
             * 1) count == 0: the name isn't in the hash: don't change the op_ppaddr
             * 2) count >  0: this *may* be a lexical method call - change the op_ppaddr
             */

            rcolon = strrchr(fqname, ':');

            /* WARN("comparing OP method (%*s) => fqname method (%s)", namelen, name, rcolon + 1); */
            if (strnEQ(name, rcolon + 1, namelen)) {
                ++count;
            }
        }

        if (count) {
            OPAnnotation * annotation;
            MethodLexicalData *data;

            data = method_lexical_data_new(aTHX_ installed, FALSE);
            annotation = op_annotation_new(METHOD_LEXICAL_ANNOTATIONS, o, (void *)data, method_lexical_data_free);

            o->op_ppaddr = method_lexical_method_static;
        } /* else no lexical method of this name */
    }
        
    done:
        return o;
}

STATIC HV *method_lexical_get_stash(pTHX_ SV * const invocant, char **packname_ptr) {
    HV *stash = NULL;
    char *packname = NULL;
    STRLEN packlen;

    SvGETMAGIC(invocant);

    if (!(invocant && SvOK(invocant))) {
        goto done;
    }

    if (SvROK(invocant)) { /* blessed reference */
        if (SvOBJECT(SvRV(invocant))) {
#ifdef HvNAME_HEK
            HEK *hek;

            if (
                (stash = SvSTASH(SvRV(invocant))) &&
                (hek = HvNAME_HEK(stash)) &&
                (packname = HEK_KEY(hek))
            ) {
                goto done;
            }
#else
            if (
                ((stash = SvSTASH(SvRV(invocant)))) &&
                (packname = HvNAME(stash))
            ) {
                goto done;
            }
#endif
        } /* unblessed reference */
    } else if ((packname = SvPV(invocant, packlen))) { /* not a reference: try package name */
        const HE *const he = hv_fetch_ent(PL_stashcache, invocant, 0, 0);

        if (he) {
            stash = INT2PTR(HV *, SvIV(HeVAL(he)));
        } else if ((stash = gv_stashpvn(packname, packlen, 0))) {
            SV *const ref = newSViv(PTR2IV(stash));
            (void) hv_store(PL_stashcache, packname, packlen, ref, 0);
        } /* can't find a stash */
    }

  done:
    *packname_ptr = packname;
    return stash;
}

STATIC void method_lexical_cache_set(
    pTHX_
    MethodLexicalData * const data,
    const HV * const stash,
    const U32 generation,
    const SV * const method,
    const CV * const cv
) {
    MethodLexicalDataList *list;

    list = method_lexical_data_list_new(aTHX_ stash, generation, method, cv);

    if (data->list) {
        list->next = data->list;
    }

    data->list = list;
}

STATIC void method_lexical_cache_remove(
    pTHX_
    MethodLexicalData * const data,
    MethodLexicalDataList *prev,
    MethodLexicalDataList *head
) {
    if (prev) { /* not first */
        prev->next = head->next;
    } else if (head->next) { /* first */
        data->list = head->next;
    } else { /* only */
        data->list = NULL;
    }

    head->next = NULL;

    method_lexical_data_list_free(aTHX_ head);
}

STATIC SV *method_lexical_cache_get(
    pTHX_
    MethodLexicalData *data,
    const HV * const stash,
    const SV * const method,
    U32 * const retval
) {
    const CV *cv = NULL;
    *retval = FALSE;

    if (data->list) {
        MethodLexicalDataList *head, *prev = NULL;

        if (data->dynamic) {
            for (head = data->list; head; prev = head, head = head->next) {
                if ((stash == head->stash) && sv_eq((SV *)method, (SV *)head->method)) { /* cast off constness */
                    if (head->generation) {
                        U32 generation = mro_get_pkg_gen(stash);

                        /* fresh: cv may be NULL, indicating (still) not found */
                        if (head->generation == generation) {
                            cv = head->cv;
                            *retval = TRUE;
                            break;
                        } else { /* stale: remove from list */
                            method_lexical_cache_remove(aTHX_ data, prev, head);
                            break;
                        }
                    } else {
                        cv = head->cv;
                        *retval = TRUE;
                        break;
                    }
                }
            }
        } else {
            for (head = data->list; head; prev = head, head = head->next) {
                if (stash == head->stash) {
                    if (head->generation) {
                        U32 generation = mro_get_pkg_gen(stash);

                        /* fresh: cv may be NULL, indicating (still) not found */
                        if (head->generation == generation) {
                            cv = head->cv;
                            *retval = TRUE;
                            break;
                        } else { /* stale: remove from list */
                            method_lexical_cache_remove(aTHX_ data, prev, head);
                            break;
                        }
                    } else {
                        cv = head->cv;
                        *retval = TRUE;
                        break;
                    }
                }
            }
        }
    }

    return (SV *)cv;
}

STATIC OP * method_lexical_method_dynamic(pTHX) {
    dSP;
    const SV * const method = TOPs;
    SV * cv;

    if (SvROK(method) && (cv = SvRV(method)) && (SvTYPE(cv) == SVt_PVCV)) {
        SETs(cv);
        RETURN;
    } else {
        const char * const method_name = SvPVX(method);
        const OPAnnotation * const annotation = op_annotation_get(METHOD_LEXICAL_ANNOTATIONS, PL_op);

        if (strchr(method_name, ':') || strchr(method_name, '\'')) {
            return CALL_FPTR(annotation->op_ppaddr)(aTHX);
        } else {
            U32 cached;
            char *class_name;
            SV * const invocant = *(PL_stack_base + TOPMARK + 1);
            const HV * const stash = method_lexical_get_stash(aTHX_ invocant, &class_name);
            MethodLexicalData * const data = (MethodLexicalData *)annotation->data;;

            cv = method_lexical_cache_get(aTHX_ data, stash, method, &cached);

            if (!cached) {
                cv = method_lexical_method_common(aTHX_ data, stash, class_name, method);
            }

            if (cv) {
                SETs(cv);
                RETURN;
            } else {
                return CALL_FPTR(annotation->op_ppaddr)(aTHX);
            }
        }
    }
}

STATIC OP *method_lexical_method_static(pTHX) {
    dSP;
    U32 cached;
    SV *cv;
    const SV * const method = cSVOP_sv;
    SV * const invocant = *(PL_stack_base + TOPMARK + 1);
    char *class_name;
    const HV * const stash = method_lexical_get_stash(aTHX_ invocant, &class_name);
    const OPAnnotation * const annotation = op_annotation_get(METHOD_LEXICAL_ANNOTATIONS, PL_op);
    MethodLexicalData * const data = (MethodLexicalData *)annotation->data;

    cv = method_lexical_cache_get(aTHX_ data, stash, method, &cached);

    if (!cached) {
        cv = method_lexical_method_common(aTHX_ data, stash, class_name, method);
    }

    if (cv) {
        XPUSHs(cv);
        RETURN;
    } else {
        return CALL_FPTR(annotation->op_ppaddr)(aTHX);
    }
}

STATIC SV * method_lexical_method_common(
    pTHX_
    MethodLexicalData * const data,
    const HV * const stash,
    const char * const class_name,
    const SV * const method
) {
    const char * method_name;
    SV *key;
    HV * const installed = data->hv;
    CV *cv = NULL;

    method_name = SvPVX(method);
    key = sv_2mortal(newSVpvf("%s::%s", class_name, method_name));
    cv = method_lexical_hash_get(aTHX_ installed, key);

    if (cv) {
        method_lexical_cache_set(aTHX_ data, stash, 0, method, cv);
    } else { /* try superclasses */
        AV *isa;
        U32 items, generation;
        SV **svp;

        generation = mro_get_pkg_gen(stash);
        isa = mro_get_linear_isa((HV *)stash); /* temporarily cast off constness */

        assert(isa);
        assert(SvTYPE(isa) == SVt_PVAV);

        items = AvFILLp(isa) + 1; /* add 1 (even though we're skipping self) to include the appended "UNIVERSAL" */
        svp = AvARRAY(isa) + 1;   /* skip self */

        while (items--) { /* always entered, if only for "UNIVERSAL" */
            SV *class_name_sv;
            char *class_name_pv;
            HV *isa_stash;

            if (items == 0) {
                class_name_sv = sv_2mortal(newSVpvn("UNIVERSAL", 9));
            } else {
                class_name_sv = *svp++;
            }

            key = sv_2mortal(newSVpvf("%s::%s", SvPVX(class_name_sv), method_name));
            assert(key);

            isa_stash = method_lexical_get_stash(aTHX_ class_name_sv, &class_name_pv);

            cv = method_lexical_hash_get(aTHX_ installed, key);

            if (cv) {
                method_lexical_cache_set(aTHX_ data, stash, generation, method, cv);
                break;
            }
        }

        if (!cv) {
            /* cache a "not found" marker: NULL */
            method_lexical_cache_set(aTHX_ data, stash, generation, method, NULL);
        }
    }

    return (SV *)cv;
}

STATIC CV *method_lexical_hash_get(pTHX_ HV * const hv, SV * const key) {
    HE *he;

    assert(hv);
    assert(SvTYPE(hv) == SVt_PVHV);
    assert(key);
    assert(SvPOK(key));

    /* warn("looking up key: %s", SvPVX(key)); */
    he = hv_fetch_ent(hv, key, FALSE, 0); /* don't create an undef value if it doesn't exist */

    if (he) {
        const SV * const rv = HeVAL(he);

        assert(rv);
        assert(SvOK(rv));
        assert(SvROK(rv));
        assert(SvRV(rv));
        assert(SvTYPE(SvRV(rv)) == SVt_PVCV);

        /* warn("found CV for %s", SvPVX(key)); */
        return (CV *)SvRV(rv);
    }

    return NULL;
}

STATIC void method_lexical_enter() {
    if (METHOD_LEXICAL_COMPILING != 0) {
        croak("method_lexical: scope overflow");
    } else {
        METHOD_LEXICAL_COMPILING = 1;
        method_lexical_check_method_id = hook_op_check(OP_METHOD, method_lexical_check_method, NULL);
    }
}

STATIC void method_lexical_leave() {
    if (METHOD_LEXICAL_COMPILING != 1) {
        croak("method_lexical: scope underflow");
    } else {
        METHOD_LEXICAL_COMPILING = 0;
        hook_op_check_remove(OP_METHOD, method_lexical_check_method_id);
    }
}

MODULE = Method::Lexical                PACKAGE = Method::Lexical

BOOT:
    if (PerlEnv_getenv("METHOD_LEXICAL_DEBUG")) {
        METHOD_LEXICAL_DEBUG = 1;
    }

    METHOD_LEXICAL_ANNOTATIONS = op_annotation_group_new();

void
END()
    CODE:
        PERL_UNUSED_VAR(cv);
        if (METHOD_LEXICAL_ANNOTATIONS) { /* make sure it was initialised */
            op_annotation_group_free(aTHX_ METHOD_LEXICAL_ANNOTATIONS);
        }

SV *
xs_get_debug()
    PROTOTYPE:
    CODE:
        PERL_UNUSED_VAR(cv);
        RETVAL = newSViv(METHOD_LEXICAL_DEBUG);
    OUTPUT:
        RETVAL

void
xs_set_debug(SV * dbg)
    PROTOTYPE:$
    CODE:
        PERL_UNUSED_VAR(cv);
        METHOD_LEXICAL_DEBUG = SvIV(dbg);

char *
xs_signature()
    PROTOTYPE:
    CODE:
        PERL_UNUSED_VAR(cv);
        RETVAL = METHOD_LEXICAL_INSTALLED;
    OUTPUT:
        RETVAL

void
xs_enter()
    PROTOTYPE:
    CODE:
        PERL_UNUSED_VAR(cv);
        method_lexical_enter();

void
xs_leave()
    PROTOTYPE:
    CODE:
        PERL_UNUSED_VAR(cv);
        method_lexical_leave();
