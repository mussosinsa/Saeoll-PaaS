package delivery.pipeline.api.cf.info;

import delivery.pipeline.api.job.CustomJob;
import org.springframework.beans.factory.annotation.Autowired;
import org.springframework.http.HttpMethod;
import org.springframework.stereotype.Service;
import delivery.pipeline.api.common.Constants;
import delivery.pipeline.api.common.RestTemplateService;

/**
 * apDeliveryPipelineApi
 * delivery.pipeline.api.cf.info
 *
 * @author REX
 * @version 1.0
 * @since 8 /31/2017
 */
@Service
public class CfInfoService {

    private final RestTemplateService restTemplateService;


    /**
     * Instantiates a new Cf info service.
     *
     * @param restTemplateService the rest template service
     */
    @Autowired
    public CfInfoService(RestTemplateService restTemplateService) {this.restTemplateService = restTemplateService;}


    /**
     * Gets cf info.
     *
     * @param customJob the custom job
     * @return the cf info
     */
    public CfInfo getCfInfo(CustomJob customJob) {
        // GET CF INFO DETAIL FROM DATABASE
        return restTemplateService.send(Constants.TARGET_COMMON_API, "/cf-info/" + customJob.getCfInfoId(), HttpMethod.GET, null, CfInfo.class);
    }

}
